import copy
import sys
import unittest
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).parents[1] / 'tools/retrieval_eval'))
from shadow import (ProfileMismatch, ShadowIndex, combine, profile_digest, rrf,
                    source_manifest)


class ShadowTests(unittest.TestCase):
    def setUp(self):
        self.manifest = source_manifest([
            {'id': x, 'title': x, 'content': 'synthetic', 'lifecycle_status': 'active'}
            for x in ['a', 'b', 'c']], 'owner-one')
        self.index = ShadowIndex(['a', 'b', 'c'],
            [[1., 0.], [0., 1.], [.6, .8]], [0, 1, 2], self.manifest, 'profile-one')

    def test_different_model_same_dimensions_rejected(self):
        with self.assertRaises(ProfileMismatch):
            self.index.rank([1., 0.], 'profile-two', self.manifest, 'owner-one')

    def test_content_update_removes_stale_highest_scoring_entry(self):
        current = copy.deepcopy(self.manifest)
        current['a']['hash'] = 'changed'
        self.assertEqual(self.index.rank([1., 0.], 'profile-one', current, 'owner-one', 2), ['c', 'b'])

    def test_superseded_deleted_and_foreign_entries_filtered(self):
        current = copy.deepcopy(self.manifest)
        current['a']['lifecycle_status'] = 'superseded'
        current['b']['owner_id'] = 'owner-two'
        del current['c']
        self.assertEqual(self.index.rank([1., 0.], 'profile-one', current, 'owner-one'), [])
        self.assertEqual(combine(['a', 'b', 'c'], None, current, 'owner-one')['ids'], [])

    def test_failure_keeps_live_baseline_order(self):
        for error in ['timeout', 'model_unavailable', 'profile_mismatch']:
            result = combine(['b', 'a'], ['c'], self.manifest, 'owner-one', failure=error)
            self.assertEqual(result['ids'], ['b', 'a'])
            self.assertEqual(result['mode'], 'baseline_fallback')

    def test_failed_baseline_is_not_masked(self):
        with self.assertRaises(ValueError):
            combine(None, ['a'], self.manifest, 'owner-one')

    def test_profile_includes_tokenizer_and_revision(self):
        self.assertNotEqual(profile_digest({'revision': 'a', 'sha256': {'tokenizer': 'a'}}),
                            profile_digest({'revision': 'a', 'sha256': {'tokenizer': 'b'}}))

    def test_invalid_vectors_and_owner_mapping_rejected(self):
        for vec in [[float('nan'), 0.], [0., 0.], [1., 0., 0.]]:
            with self.assertRaises(ValueError):
                self.index.rank(vec, 'profile-one', self.manifest, 'owner-one')
        with self.assertRaises(ValueError):
            ShadowIndex(['a'], [[1., 0.]], [3], {'a': self.manifest['a']}, 'x')

    def test_fusion_has_fixed_weights_unique_results_and_deterministic_ties(self):
        self.assertEqual(rrf(['b', 'a'], ['a', 'c']), ['a', 'b', 'c'])
        with self.assertRaises(ValueError):
            rrf(['a', 'a'], ['b'])


if __name__ == '__main__':
    unittest.main()
