import importlib.util
from pathlib import Path
import unittest
import numpy as np

spec = importlib.util.spec_from_file_location('evaluation',Path(__file__).parents[1]/'tools/retrieval_eval/evaluate.py')
evaluation = importlib.util.module_from_spec(spec)
spec.loader.exec_module(evaluation)


class EvaluationTests(unittest.TestCase):
    def test_windows_preserve_tail_and_every_token(self):
        for length in [1,384,385,512,513,5000]:
            spans=list(evaluation.windows(length))
            self.assertEqual(spans[-1][1],length)
            covered={i for start,end in spans for i in range(start,end)}
            self.assertEqual(covered,set(range(length)))
            self.assertTrue(all(end-start<=384 for start,end in spans))

    def test_invalid_overlap(self):
        for overlap in [-1,384,500]:
            with self.assertRaises(ValueError):list(evaluation.windows(100,384,overlap))

    def test_multiple_chunks_do_not_take_multiple_result_slots(self):
        s=evaluation.aggregate_chunks(np.array([[.4,.9,.8],[.7,.2,.3]]),[0,0,1],2)
        np.testing.assert_allclose(s,[[.9,.8],[.7,.3]])

    def test_metrics_count_absence_and_rank_six(self):
        cases=[{'case_id':'a','relevant_ids':['a']},{'case_id':'b','relevant_ids':['b']},
               {'case_id':'c','relevant_ids':['z']}]
        m=evaluation.metrics(cases,{'a':['a'],'b':['1','2','3','4','5','b'],'c':['x']})
        self.assertEqual(m['hits_at_1'],1)
        self.assertEqual(m['hits_at_6'],2)
        self.assertAlmostEqual(m['mrr_at_6'],(1+1/6)/3)

    def test_duplicate_rankings_rejected(self):
        with self.assertRaises(ValueError):
            evaluation.metrics([{'case_id':'a','relevant_ids':['x']}],{'a':['x','x']})


if __name__ == '__main__':unittest.main()
