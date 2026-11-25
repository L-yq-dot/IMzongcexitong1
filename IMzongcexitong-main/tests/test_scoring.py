"""确定性规则计算的离线单元测试（不调用 DeepSeek）。"""
import unittest

import scoring


class ScoringRules(unittest.TestCase):
    def test_paper_first_author(self):
        score, _ = scoring._calculate("paper", {"subtype": "JCR一区", "author_rank": 1, "author_count": 3})
        self.assertEqual(score, 3.6)

    def test_paper_other_authors_split(self):
        score, _ = scoring._calculate("paper", {"subtype": "JCR一区", "author_rank": 2, "author_count": 3})
        self.assertEqual(score, 1.2)

    def test_competition_team_split(self):
        score, _ = scoring._calculate("competition", {"award_level": "校级", "award_rank": "一等奖", "team_size": 2})
        self.assertEqual(score, 1.0)

    def test_patent_author_formula(self):
        score, _ = scoring._calculate("ip", {"subtype": "发明专利", "author_rank": 1, "author_count": 3})
        self.assertEqual(score, 1.0)

    def test_book_first_responsible(self):
        score, _ = scoring._calculate("book", {"subtype": "学术专著", "author_rank": 1, "author_count": 2})
        self.assertEqual(score, 5.0)

    def test_project_independent(self):
        score, _ = scoring._calculate("project", {"subtype": "独立完成"})
        self.assertEqual(score, 3.0)

    def test_unknown_rule(self):
        score, _ = scoring._calculate("social_work", {})
        self.assertIsNone(score)


if __name__ == "__main__":
    unittest.main()
