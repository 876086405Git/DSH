#!/usr/bin/env python3
"""The native contract reads its names from the sources and refuses anything older."""
import importlib.util
from pathlib import Path
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[3]
spec = importlib.util.spec_from_file_location('native_contract', ROOT / 'tooling/ohos/native_contract.py')
contract = importlib.util.module_from_spec(spec)
spec.loader.exec_module(contract)


def images(root=ROOT):
    binding = contract.binding_names((root / contract.BINDING).read_text())
    host = (root / contract.HOST).read_text()
    return (b'\0'.join(name.encode() for name in binding) + b'\0',
            b'\0'.join(name.encode() for name in contract.host_methods(host)) + b'\0',
            contract.host_exports(host))


class Contract(unittest.TestCase):
    def test_current_sources_name_every_entry_and_a_matching_set_passes(self):
        libnode, host, exported = images()
        self.assertEqual(contract.check(libnode, host, exported), [])
        self.assertIn('getHostLifecycleSnapshot', contract.binding_names((ROOT / contract.BINDING).read_text()))

    def test_each_missing_binding_entry_is_a_problem(self):
        libnode, host, exported = images()
        for name in contract.binding_names((ROOT / contract.BINDING).read_text()):
            stale = libnode.replace(name.encode() + b'\0', b'')
            problems = contract.check(stale, host, exported)
            self.assertEqual(len(problems), 1, name)
            self.assertIn(f'no binding entry {name}', problems[0])

    def test_each_missing_host_method_and_export_is_a_problem(self):
        libnode, host, exported = images()
        for name in contract.host_methods((ROOT / contract.HOST).read_text()):
            self.assertIn(f'no method {name}', contract.check(libnode, host.replace(name.encode() + b'\0', b''), exported)[0])
        for name in exported:
            self.assertIn(f'does not export {name}', contract.check(libnode, host, exported - {name})[0])

    def test_names_come_from_literals_and_name_arrays(self):
        source = '''const char* names[]={"one","two"};
        napi_set_named_property(env,exports,names[i],function);
        napi_set_named_property(env, exports, "three", function);'''
        self.assertEqual(contract.binding_names(source), {'one', 'two', 'three'})

    def test_a_shape_it_cannot_read_stops_instead_of_shrinking_the_list(self):
        with self.assertRaises(ValueError):
            contract.binding_names('napi_set_named_property(env, exports, computeName(), function);')
        with self.assertRaises(ValueError):
            contract.binding_names('nothing registered here')

    def test_runtime_asking_for_an_unregistered_entry_is_a_problem(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            for relative in (contract.BINDING, contract.HOST, contract.DECLARATIONS):
                (root / relative).parent.mkdir(parents=True, exist_ok=True)
                (root / relative).write_bytes((ROOT / relative).read_bytes())
            module = root / 'runtime/ohos/x.mjs'
            module.write_text("const binding = process._linkedBinding('dsh_ohos_publication'); binding.neverRegistered();\n")
            libnode, host, exported = images(root)
            problems = contract.check(libnode, host, exported, root)
            self.assertEqual(len(problems), 1)
            self.assertIn('binding.neverRegistered', problems[0])


if __name__ == '__main__':
    unittest.main()
