"""NVN's fixed-function alpha test: the generated entry points (dmsh_build.py fs_alpha) and, opt-in, the windowless GPU test through the real draw/replay path."""
import ast
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
from typing import Any
import unittest

ROOT = Path(__file__).resolve().parents[3]
BUILD = ROOT / 'dm/gfx/tools/dmsh_build.py'
# dmsh_build is a CLI with profile/build side effects; load only its pure rewrite functions.
TREE = ast.parse(BUILD.read_text())
NS: dict[str, Any] = {'re': re}   # the exec'd functions below: pyright would otherwise infer the dict's values from 're' (a module)
exec(compile(ast.Module(body=[n for n in TREE.body if isinstance(n, ast.FunctionDef)
                             and n.name in ('fs_uint', 'fs_alpha')], type_ignores=[]), str(BUILD), 'exec'), NS)
fs_alpha, fs_uint = NS['fs_alpha'], NS['fs_uint']
SOURCE = '''#include <metal_stdlib>
using namespace metal;
struct main0_out { float4 colour [[color(0)]]; };
fragment main0_out main0(float4 position [[position]]) {
    main0_out out = {};
    out.colour = float4(1, 0, 0, position.x * 0.25f);
    return out;
}
'''


class AlphaRewriteTests(unittest.TestCase):
    def test_original_entry_unchanged(self):
        result, entries = fs_alpha(SOURCE)
        self.assertTrue(result.startswith(SOURCE))
        self.assertEqual(entries, {'entry_alpha': 'main0_at'})
        self.assertIn('constant dm_alpha_test_params& dm_alpha [[buffer(1)]]', result)
        self.assertIn('if (!dm_alpha_pass(out.colour.w, dm_alpha)) discard_fragment();', result)

    def test_all_comparison_modes(self):
        result, _ = fs_alpha(SOURCE)
        for n, comparison in enumerate(('false', 'a < p.ref', 'a == p.ref', 'a <= p.ref',
                                        'a > p.ref', 'a != p.ref', 'a >= p.ref'), 1):
            self.assertIn(f'case {n}: return {comparison};', result)
        self.assertIn('default: return true;', result)

    def test_no_arguments(self):
        result, _ = fs_alpha(SOURCE.replace('float4 position [[position]]', '').replace('position.x * 0.25f', '.5f'))
        self.assertIn('main0_at(constant dm_alpha_test_params& dm_alpha [[buffer(1)]])', result)

    def test_nested_body_and_multiple_returns(self):
        src = SOURCE.replace('    return out;', '    if (position.x < 2) { return out; }\n    return out;')
        result, _ = fs_alpha(src)
        self.assertEqual(result.count('discard_fragment()'), 2)

    def test_early_depth_tests_removed_only_from_alpha_variant(self):
        src = SOURCE.replace('fragment main0_out', '[[early_fragment_tests]]\nfragment main0_out')
        result, _ = fs_alpha(src)
        self.assertEqual(result.count('[[early_fragment_tests]]'), 1)

    def test_integer_and_mixed_entries_test_original_float_alpha(self):
        src = SOURCE.replace('float4 colour [[color(0)]];',
                             'float4 colour [[color(0)]];\n    float4 second [[color(1)]];')
        src = src.replace('    return out;', '    out.second = as_type<float4>(uint4(1));\n    return out;')
        integer, mask = fs_uint(src)
        self.assertEqual(mask, 2)
        result, entries = fs_alpha(integer)
        self.assertEqual(entries, {'entry_alpha': 'main0_at', 'entry_alpha_u': 'main0_u_at',
                                   'entry_alpha_m': 'main0_m_at'})
        self.assertEqual(result.count('dm_alpha_pass(out.colour.w, dm_alpha)'), 3)
        for name in ('main0_u_at', 'main0_m_at'):
            body = result[result.index(name + '('):]
            self.assertLess(body.index('discard_fragment()'), body.index('return main0_out_'))

    def test_no_colour_zero_has_no_alpha_entry(self):
        src = SOURCE.replace('[[color(0)]]', '[[color(1)]]')
        self.assertEqual(fs_alpha(src), (src, {}))


class AlphaGpuTests(unittest.TestCase):
    """The comparisons and the depth-write suppression, on the GPU, through draw/replay: `make -C dm/gfx/tests check_t_alpha_test`"""
    @unittest.skipUnless(os.environ.get('DM_TEST_ALPHA_METAL') and shutil.which('xcrun'), 'set DM_TEST_ALPHA_METAL to the native t_alpha_test executable')
    def test_windowless_real_replay(self):
        # Compile the generated MSL, not a hand-written approximation of the lowering.
        result, _ = fs_alpha(SOURCE)
        result += '''
vertex float4 near_vertex(uint id [[vertex_id]]) {
    float2 p = float2(float((id << 1) & 2), float(id & 2));
    return float4(p * 2.0f - 1.0f, 0.25f, 1.0f);
}
vertex float4 far_vertex(uint id [[vertex_id]]) {
    float2 p = float2(float((id << 1) & 2), float(id & 2));
    return float4(p * 2.0f - 1.0f, 0.75f, 1.0f);
}
fragment float4 background() { return float4(0, 0, 1, 1); }
'''
        with tempfile.TemporaryDirectory(prefix='nvn-alpha-') as tmp:
            msl = Path(tmp) / 'alpha.metal'
            msl.write_text(result)
            env = {k: v for k, v in os.environ.items() if not k.startswith('DM_')}   # the test's own enable flags stay out
            env['DM_PSO_CACHE_DIR'] = str(Path(tmp) / 'pipeline-cache')
            p = subprocess.run([os.environ['DM_TEST_ALPHA_METAL'], str(msl)], env=env, capture_output=True, text=True)
            if p.returncode == 77:
                self.skipTest('Metal device unavailable')
            self.assertEqual(p.returncode, 0, p.stdout + p.stderr)
            self.assertIn('0 failed', p.stdout)


if __name__ == '__main__':
    unittest.main()
