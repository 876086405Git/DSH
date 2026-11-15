"""Private, declared configuration bundle and absolute-path native fixture."""
import hashlib
import json
from pathlib import Path


def prepare_bridge_fixture(runtime, dsh, out):
    here = Path(__file__).resolve().parent
    private = out / 'bridge-fixtures'
    private.mkdir(exist_ok=False)
    schema = (runtime / 'node_modules/@deepseek-ai/schemastery/lib/index.mjs').as_uri()
    native = private / 'native'
    native.mkdir()
    (native / 'index.mjs').write_text((here / 'host-bridge-fixture/native.mjs').read_text().replace('__SCHEMA_MODULE__', schema))
    (native / 'package.json').write_bytes((here / 'host-bridge-fixture/package.json').read_bytes())
    (native / 'assets').mkdir()
    asset = native / 'assets/proof.png'
    asset.write_bytes((here / 'host-bridge-fixture/proof.png').read_bytes())

    def save(path, value):
        path.write_text(json.dumps(value, ensure_ascii=False, indent=2) + '\n')

    plugin = private / 'config-plugin'
    plugin.mkdir()
    (plugin / 'index.mjs').write_text('import z from ' + json.dumps(schema) + ';\n'
        "export const name='dsh-go-fixture-host-config';\n"
        "export const Config=z.object({label:z.string().default('initial-label')});\n"
        'export function apply(){}\n')
    save(plugin / 'package.json', {'name': 'dsh-go-fixture-host-config', 'version': '1.0.0', 'type': 'module',
        'exports': {'.': './index.mjs', './package.json': './package.json'}})
    bundle = private / 'config-bundle'
    bundle.mkdir()
    (bundle / 'index.mjs').write_text('export function apply(){}\n')
    save(bundle / 'package.json', {'name': 'dsh-go-fixture-host-config-bundle', 'version': '1.0.0',
        'type': 'module', 'exports': {'.': './index.mjs', './package.json': './package.json',
        './cordis.patch.yml': './cordis.patch.yml'},
        'dependencies': {'dsh-go-fixture-host-config': 'file:' + str(plugin)},
        'dsh': {'bundle': {'patch': './cordis.patch.yml'}}})
    save(bundle / 'cordis.patch.yml', [{'insert': [{'id': 'add12-owned-config', 'name': 'dsh-go-fixture-host-config'}]}])
    (bundle / 'node_modules').mkdir()
    (bundle / 'node_modules/dsh-go-fixture-host-config').symlink_to(plugin, target_is_directory=True)

    profile = dsh / 'profiles/web'
    profile.mkdir(parents=True, exist_ok=True)
    manifest_path = profile / 'package.json'
    manifest = json.loads(manifest_path.read_text()) if manifest_path.exists() else {
        'name': 'dsh-profile-web', 'private': True, 'dependencies': {},
        'dsh': {'profile': {'bundles': ['@deepseek-ai/dsh-base', '@deepseek-ai/dsh-web-app']}}}
    assert manifest['dsh']['profile']['bundles'] == ['@deepseek-ai/dsh-base', '@deepseek-ai/dsh-web-app']
    assert manifest['dependencies'] == {}, 'Only the newly created private profile is eligible'
    manifest['dependencies'] = {'dsh-go-fixture-host-config': 'file:' + str(plugin),
                               'dsh-go-fixture-host-config-bundle': 'file:' + str(bundle)}
    manifest['dsh']['profile']['bundles'].append('dsh-go-fixture-host-config-bundle')
    save(manifest_path, manifest)
    patch = profile / 'cordis.patch.yml'
    # dsh-app-boot creates this commented empty template during --dump-config.
    # Only that exact known template, or an already empty array, is eligible.
    default_empty = ('# Your patch layer for this dsh profile, applied after every bundle layer:\n'
                     '# a top-level YAML array of loader patch entries (id-targeted config\n'
                     '# overrides, disables, and insert lists; `!!js` expressions allowed).\n[]')
    assert not patch.exists() or patch.read_text().strip() in ['', '[]', default_empty], 'Never overwrite a nonempty profile'
    save(patch, [{'insert': [{'id': 'add12-owned-fixture', 'name': str(native / 'index.mjs')}]}])
    # This fixture never inserts the bridge. Only the production Host profile may do so.
    modules = profile / 'node_modules'
    modules.mkdir(exist_ok=True)
    for name, target in [('dsh-go-fixture-host-config', plugin), ('dsh-go-fixture-host-config-bundle', bundle)]:
        (modules / name).symlink_to(target, target_is_directory=True)
    files = {}
    for root in [private, profile]:
        for path in sorted(root.rglob('*')):
            if path.is_symlink():
                files[str(path)] = {'link': str(path.readlink())}
            elif path.is_file():
                files[str(path)] = {'bytes': path.stat().st_size,
                                    'sha256': hashlib.sha256(path.read_bytes()).hexdigest()}
    save(out / 'bridge-fixture-input.json', files)
    return {'pkg': 'dsh-go-fixture-host-bridge', 'entryId': 'add12-owned-config',
            'nativeEntryId': 'add12-owned-fixture',
            'assetSHA256': hashlib.sha256(asset.read_bytes()).hexdigest()}
