import { createHash } from 'node:crypto';
import { isUtf8 } from 'node:buffer';

// These identities are the agent/init inputs of the six assets (agent from 940).
// A driver must also bind its actual asset manifest, native library and source.
const AGENT_SHA256 = 'e8069c237ef2960c2b5558d610210355375109a7f3bc866c1303d3bf1cffb9a0';
const INIT_SHA256 = '2debca599bdab558987fc6e65a284cbba0b7dc4c654cb47e99f45d2ac9d3e95f';
const DATA_BYTES = 1024 * 1024;
const digest = bytes => createHash('sha256').update(bytes).digest('hex');
const DATA_SHA256 = (() => {
  const bytes = Buffer.alloc(DATA_BYTES);
  for (let i = 0; i < bytes.length; i++) bytes[i] = i & 255;
  return digest(bytes);
})();
const CONFIG_TEXT = JSON.stringify({ format: 1, note: 'normal-close-then-new-process',
  payloadBytes: DATA_BYTES, payloadSha256: DATA_SHA256 }) + '\n';
const COMMON = Object.freeze({
  uid: 60081, gid: 60081,
  data: Object.freeze({ path: '/workspace/931-persistence.bin', bytes: DATA_BYTES, sha256: DATA_SHA256, mode: '0o600' }),
  config: Object.freeze({ path: '/workspace/.config/dsh931/settings.json', bytes: Buffer.byteLength(CONFIG_TEXT), sha256: digest(CONFIG_TEXT), mode: '0o600' }),
  agent: Object.freeze({ path: '/usr/local/lib/dsh/guest-agent.py', bytes: 21575, sha256: AGENT_SHA256, mode: '0o644' }),
  init: Object.freeze({ path: '/sbin/dsh-init', bytes: 687, sha256: INIT_SHA256, mode: '0o755' }),
});

// Executed only inside the real guest through the production backend. There is
// deliberately no sync, fsync, syncfs or shell command in this measurement job.
// Closing ordinary file handles leaves writeback to production guest shutdown.
const PYTHON = String.raw`
import hashlib,json,os,stat,sys
phase=sys.argv[1]
if phase not in ('write','read'):
    raise ValueError('invalid witness phase')
data_path='/workspace/931-persistence.bin'
config_directory='/workspace/.config/dsh931'
config_path=config_directory+'/settings.json'
target_device='/dev/vdc' if phase=='write' else '/dev/vda'

def metadata(info):
    return {'bytes':info.st_size,'uid':info.st_uid,'gid':info.st_gid,
            'mode':oct(stat.S_IMODE(info.st_mode)),'inode':info.st_ino,
            'mtimeNs':str(info.st_mtime_ns),
            'device':{'major':os.major(info.st_dev),'minor':os.minor(info.st_dev)}}

def file_record(path):
    fd=os.open(path,os.O_RDONLY|os.O_CLOEXEC|os.O_NOFOLLOW)
    with os.fdopen(fd,'rb') as stream:
        info=os.fstat(stream.fileno())
        if not stat.S_ISREG(info.st_mode) or info.st_size>2*1024*1024:
            raise ValueError('witness input is not a bounded regular file')
        digest=hashlib.sha256()
        for chunk in iter(lambda:stream.read(65536),b''):
            digest.update(chunk)
    return {'path':path,**metadata(info),'sha256':digest.hexdigest()}

def directory_record(path):
    info=os.lstat(path)
    if not stat.S_ISDIR(info.st_mode):
        raise ValueError('witness directory is not a directory')
    return {'path':path,**metadata(info)}

def write_new(path,content):
    fd=os.open(path,os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_CLOEXEC|os.O_NOFOLLOW,0o600)
    with os.fdopen(fd,'wb') as stream:
        stream.write(content)

if phase=='write':
    content=bytes(range(256))*4096
    write_new(data_path,content)
    os.makedirs(config_directory,mode=0o700,exist_ok=False)
    config={'format':1,'note':'normal-close-then-new-process',
            'payloadBytes':len(content),'payloadSha256':hashlib.sha256(content).hexdigest()}
    write_new(config_path,(json.dumps(config,sort_keys=True,separators=(',',':'))+'\n').encode())

mounts=[]
with open('/proc/mounts',encoding='utf-8') as stream:
    for line in stream:
        fields=line.split()
        if len(fields)>=4 and fields[1]=='/':
            mounts.append({'source':fields[0],'target':fields[1],'type':fields[2],
                           'options':fields[3].split(','),'raw':line.rstrip('\n')})
device=os.lstat(target_device)
uname=os.uname()
record={'v':1,'phase':phase,'uid':os.getuid(),'gid':os.getgid(),
        'pythonVersion':sys.version.split()[0],
        'uname':dict(zip(('system','nodeName','release','version','machine'),uname)),
        'root':directory_record('/'),'rootMounts':mounts,
        'targetDevice':{'path':target_device,'isBlock':stat.S_ISBLK(device.st_mode),
                        'major':os.major(device.st_rdev),'minor':os.minor(device.st_rdev)},
        'workspace':directory_record('/workspace'),
        'configDirectory':directory_record(config_directory),
        'agent':file_record('/usr/local/lib/dsh/guest-agent.py'),
        'init':file_record('/sbin/dsh-init'),
        'data':file_record(data_path),'config':file_record(config_path)}
print(json.dumps(record,separators=(',',':'),sort_keys=True),flush=True)
`;

const fail = message => Object.assign(new Error(message), { code: 'ERR_OHOS_LINUX_RESUME_WITNESS' });
function check(value, message) { if (!value) throw fail(message); }
function expectedFor(phase) {
  check(phase === 'write' || phase === 'read', 'Unknown guest witness phase');
  return Object.freeze({ ...COMMON, phase, targetDevice: phase === 'write' ? '/dev/vdc' : '/dev/vda' });
}

export function witnessCommands({ phase } = {}) {
  const expected = expectedFor(phase);
  return Object.freeze([Object.freeze({ name: 'guest-witness-' + phase,
    cwd: '/workspace', argv: Object.freeze(['python3', '-c', PYTHON, phase]), expected })]);
}

function decode(stdout) {
  if (Buffer.isBuffer(stdout)) {
    check(stdout.length <= 65536 && isUtf8(stdout), 'Witness stdout must be bounded UTF-8');
    stdout = stdout.toString('utf8');
  }
  if (typeof stdout === 'string') {
    check(Buffer.byteLength(stdout) <= 65536, 'Witness stdout exceeds bound');
    try { stdout = JSON.parse(stdout); } catch { throw fail('Witness stdout is not one JSON document'); }
  }
  check(stdout && typeof stdout === 'object' && !Array.isArray(stdout), 'Witness record must be an object');
  return stdout;
}
function checkMetadata(actual, { path, uid, gid, mode }) {
  check(actual?.path === path && actual.uid === uid && actual.gid === gid && actual.mode === mode,
    'Witness ownership or mode mismatch: ' + path);
  check(Number.isSafeInteger(actual.inode) && actual.inode > 0 &&
    typeof actual.mtimeNs === 'string' && /^(0|[1-9][0-9]{0,20})$/.test(actual.mtimeNs),
  'Witness inode or mtime is invalid: ' + path);
}
function checkFile(actual, expected, uid, gid) {
  checkMetadata(actual, { ...expected, uid, gid });
  check(actual.bytes === expected.bytes && actual.sha256 === expected.sha256,
    'Witness bytes or SHA mismatch: ' + expected.path);
}

// Validate only guest observations. The caller must separately require the real
// backend outcome, this epoch's closed, native retirement, and clean commit.
export function validateWitnessResult({ phase, stdout } = {}) {
  const expected = expectedFor(phase), record = decode(stdout);
  check(record.v === 1 && record.phase === phase && record.uid === expected.uid && record.gid === expected.gid,
    'Witness phase or actual job identity mismatch');
  check(record.uname?.system === 'Linux' && record.uname.machine === 'riscv64' &&
    typeof record.uname.release === 'string' && record.uname.release.length > 0 &&
    typeof record.uname.version === 'string' && record.uname.version.length > 0,
  'Actual guest kernel identity is missing');
  check(typeof record.pythonVersion === 'string' && record.pythonVersion.length > 0, 'Actual guest Python version is missing');
  checkMetadata(record.root, { path: '/', uid: 0, gid: 0, mode: '0o755' });
  checkMetadata(record.workspace, { path: '/workspace', uid: expected.uid, gid: expected.gid, mode: '0o700' });
  checkMetadata(record.configDirectory, { path: '/workspace/.config/dsh931', uid: expected.uid, gid: expected.gid, mode: '0o700' });
  const device = record.targetDevice, rootDevice = record.root.device;
  check(device?.path === expected.targetDevice && device.isBlock === true &&
    Number.isSafeInteger(device.major) && device.major >= 0 && Number.isSafeInteger(device.minor) && device.minor >= 0 &&
    rootDevice?.major === device.major && rootDevice?.minor === device.minor,
  'Guest root filesystem does not correspond to the intended target block device');
  check(Array.isArray(record.rootMounts) && record.rootMounts.some(mount => mount.target === '/' &&
    mount.type === 'ext4' && Array.isArray(mount.options) && mount.options.includes('rw') &&
    [expected.targetDevice, '/dev/root'].includes(mount.source) && typeof mount.raw === 'string' && mount.raw.length > 0),
  'Actual writable ext4 root mount was not observed');
  checkFile(record.agent, expected.agent, 0, 0);
  checkFile(record.init, expected.init, 0, 0);
  checkFile(record.data, expected.data, expected.uid, expected.gid);
  checkFile(record.config, expected.config, expected.uid, expected.gid);
  for (const name of ['workspace', 'configDirectory', 'agent', 'init', 'data', 'config'])
    check(record[name].device?.major === rootDevice.major && record[name].device?.minor === rootDevice.minor,
      'Witness path is outside the root filesystem sync scope: ' + name);
  return record;
}

export function compareWitnessResults(write, read) {
  write = validateWitnessResult({ phase: 'write', stdout: write });
  read = validateWitnessResult({ phase: 'read', stdout: read });
  for (const name of ['data', 'config']) {
    for (const field of ['path', 'bytes', 'sha256', 'uid', 'gid', 'mode', 'inode', 'mtimeNs'])
      check(write[name][field] === read[name][field], 'Persistent witness changed across guest lifetimes: ' + name + '.' + field);
  }
  for (const name of ['workspace', 'configDirectory']) {
    for (const field of ['path', 'uid', 'gid', 'mode', 'inode'])
      check(write[name][field] === read[name][field], 'Persistent directory changed across guest lifetimes: ' + name + '.' + field);
  }
  for (const field of ['system', 'release', 'version', 'machine'])
    check(write.uname[field] === read.uname[field], 'Kernel changed between the paired guest lifetimes');
  return { dataPreserved: true, configPreserved: true, fileIdentityPreserved: true,
    installedAgentSha256: read.agent.sha256, installedInitSha256: read.init.sha256,
    kernelRelease: read.uname.release, rootDevices: [write.targetDevice.path, read.targetDevice.path],
    scope: 'Guest metadata and bytes only; close/native/checkpoint facts remain separate requirements' };
}
