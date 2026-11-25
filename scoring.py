"""规则匹配 + DeepSeek AI 初审草稿。

设计原则：
- 能由细则直接算的（论文/著作/课题/竞赛/知识产权）在 AI 识别出结构化信息后由本地规则复算；
- 主观或信息不足的（社会工作、志愿、实践活动）采用 AI 建议分；
- AI 只生成草稿，最终分数由 review_record 记录，人工可采纳或覆盖。
"""
from __future__ import annotations

import json
import os
from pathlib import Path
import urllib.error
import urllib.request

PROMPT_VERSION = "v1"


class AIError(RuntimeError):
    pass


def _load_env() -> None:
    path = Path(__file__).with_name(".env")
    if not path.is_file():
        return
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        os.environ.setdefault(key.strip(), value.strip())


_load_env()

RUBRIC = """北京大学信息管理系本科生素质综合测评（2026年5月修订）：
S = A 基本素质（满分20）+ B1 学业成绩（满分80）+ B2 学术科研（加分）+ C 实践能力（加分）。
A 由学生互评15 + 班主任/辅导员评价10，合计25后乘0.8；受纪律处分则 A 不合格。
B1：24级及以前 = 课程平均绩点 × 20；25级及以后 = 课程成绩加权平均分 × 0.8；合格制/等级制课程不计。
学业不合格：上一学年两门必修课不及格。
结果只有优秀/合格/不合格；优秀不超过年级测评范围20%；A不合格或学业不合格直接不合格。

B2 学术科研（基础0）：
1. 论文：SCI/SSCI/AHCI 4分/篇，JCR一区6；EI期刊3；CCF-A会议6，CCF-B会议3，EI会议2，其它国际会议1.5，国际会议海报0.5；国内核心2；被新华文摘/中国社会科学文摘/人大复印报刊资料转载1。合作论文第一作者或通讯作者（导师第一）拿60%，其他作者平均分剩余40%。
2. 著作：学术专著10/部，编著6，译著5，中文著作注释及译文2。第一责任者50%，其他责任者平均分剩余50%。
3. 课题：独立完成学校正式批复课题3/项；合作课题主持人60%，其他参加者平均分剩余40%；参与本系教师正式立项课题：国家级1，其它0.5，多个项目（至少含一个国家级）累计最高1.5。
4. 竞赛：教育部名单A类，院系级特/一/二/三等奖 2/1.5/1/0.5，校级 2.5/2/1.5/1，市级 3/2.5/2/1.5，全国级 3.5/3/2.5/2；B类全国级 2.5/2/1.5/1。团队平均分；同一项目多次获奖取最高；每学年不超过2项。
5. 知识产权：发明专利授权2/项，软件著作权1/项；合作按作者顺序 Wi=(n-i+1)/Σ(k=1..n)k 分配；每学年不超过2项。

C 实践能力（基础0）：
1. 社会工作：系学生会主席/学生党支部书记0-3；团委学生副书记/学生会副主席0-2；部长/青协秘书长/团校秘书长/班长/团支书0-1.5；副部长/党支部委员0-1；校学生会主席/常代会会长0-4，校团委副部长/校学生会副主席/常代会副会长0-3，校学生会/常代会部长0-2，副部长0-1；社团社长/理事长/团支书0.5；学生助理0-0.5；多项按最高一项，不累计。
2. 志愿服务：按“志愿北京”总时长在测评范围内排名，前10%加1，10%-20%加0.8，20%-30%加0.5。
3. 实践活动：新生杯/北大杯/硕博杯/校运动会（趣味除外）第一名1、第二三名0.5；新生杯/北大之锋辩论赛决赛主力1；十佳歌手前十1；剧星风采决赛1；演讲十佳决赛1；示范学生宿舍0.5；军训优秀学员0.5；不同赛事各取最高一项。
"""

SYSTEM = (
    "你是北京大学信息管理系学生素质综合测评的规则初审助手。"
    "请严格按给定细则匹配加分规则并给出建议分，只输出一个 JSON 对象，不要输出 markdown 或解释文字。"
    "JSON 字段：matched_rule（paper/book/project/competition/ip/social_work/volunteer/practice/other）、"
    "subtype（如 JCR一区、CCF-A会议、校级一等奖、发明专利、软件著作权、班长等）、"
    "author_rank、author_count、team_size、award_level（院系级/校级/市级/全国级）、"
    "award_rank（特等奖/一等奖/二等奖/三等奖）、hours、suggested_score、confidence（0-1）、"
    "rationale（中文，简述依据）、needs_human（true/false）。"
    "suggested_score 不得超过单项上限；信息不足或主观项时降低 confidence 并置 needs_human=true。"
)


def _chat(messages: list[dict]) -> str:
    key = os.getenv("DEEPSEEK_API_KEY")
    if not key:
        raise AIError("未配置 DEEPSEEK_API_KEY")
    base = os.getenv("DEEPSEEK_BASE_URL", "https://api.deepseek.com").rstrip("/")
    payload = json.dumps({
        "model": os.getenv("DEEPSEEK_MODEL", "deepseek-chat"),
        "messages": messages,
        "temperature": 0,
        "max_tokens": 900,
    }).encode("utf-8")
    request = urllib.request.Request(base + "/chat/completions", data=payload, headers={
        "Content-Type": "application/json",
        "Authorization": "Bearer " + key,
    })
    try:
        with urllib.request.urlopen(request, timeout=int(os.getenv("DEEPSEEK_TIMEOUT", "30"))) as response:
            data = json.loads(response.read().decode("utf-8"))
    except urllib.error.HTTPError as error:
        raise AIError(f"DeepSeek 返回 HTTP {error.code}") from None
    except (urllib.error.URLError, TimeoutError, OSError) as error:
        raise AIError("DeepSeek 网络请求失败") from None
    try:
        return data["choices"][0]["message"]["content"]
    except (KeyError, IndexError, TypeError):
        raise AIError("DeepSeek 返回格式异常") from None


def _parse(content: str) -> dict:
    text = content.strip()
    if text.startswith("```"):
        text = text.split("\n", 1)[-1]
        text = text.rsplit("```", 1)[0]
    start, end = text.find("{"), text.rfind("}")
    if start < 0 or end <= start:
        raise AIError("AI 未返回 JSON")
    try:
        return json.loads(text[start:end + 1])
    except json.JSONDecodeError:
        raise AIError("AI 返回的 JSON 无法解析") from None


def _number(value, default=None):
    try:
        return float(value)
    except (TypeError, ValueError):
        return default


def _int(value):
    number = _number(value)
    return int(number) if number is not None and number >= 0 else None


def _paper(points: float, rank, count) -> float:
    rank, count = _int(rank), _int(count)
    if rank == 1:
        return points * 0.6
    if rank and count and count > 1:
        return points * 0.4 / (count - 1)
    return points


def _book(points: float, rank, count) -> float:
    rank, count = _int(rank), _int(count)
    if rank == 1:
        return points * 0.5
    if rank and count and count > 1:
        return points * 0.5 / (count - 1)
    return points


def _ip(points: float, rank, count) -> float:
    rank, count = _int(rank), _int(count)
    if rank and count and 1 <= rank <= count:
        total = count * (count + 1) / 2
        return points * (count - rank + 1) / total
    return points


def _competition(level: str, award: str, category: str, team) -> float | None:
    table = {
        ("院系级", "特等奖"): 2, ("院系级", "一等奖"): 1.5, ("院系级", "二等奖"): 1, ("院系级", "三等奖"): 0.5,
        ("校级", "特等奖"): 2.5, ("校级", "一等奖"): 2, ("校级", "二等奖"): 1.5, ("校级", "三等奖"): 1,
        ("市级", "特等奖"): 3, ("市级", "一等奖"): 2.5, ("市级", "二等奖"): 2, ("市级", "三等奖"): 1.5,
        ("全国级", "特等奖"): 3.5, ("全国级", "一等奖"): 3, ("全国级", "二等奖"): 2.5, ("全国级", "三等奖"): 2,
    }
    if category == "B" and level == "全国级":
        points = {"特等奖": 2.5, "一等奖": 2, "二等奖": 1.5, "三等奖": 1}.get(award)
    else:
        points = table.get((level, award))
    if points is None:
        return None
    team = _int(team) or 1
    return points / team


def _calculate(rule_key: str, data: dict) -> tuple[float | None, str]:
    subtype = str(data.get("subtype") or data.get("matched_rule_detail") or "").lower()
    rank, count = data.get("author_rank"), data.get("author_count")
    if rule_key == "paper":
        if "jcr" in subtype and ("一区" in subtype or "q1" in subtype):
            points, name = 6, "JCR一区"
        elif "sci" in subtype or "ssci" in subtype or "ahci" in subtype:
            points, name = 4, "SCI/SSCI/AHCI"
        elif "ccf-a" in subtype or "ccf a" in subtype:
            points, name = 6, "CCF-A会议"
        elif "ccf-b" in subtype or "ccf b" in subtype:
            points, name = 3, "CCF-B会议"
        elif "ei" in subtype and ("会议" in subtype or "conference" in subtype):
            points, name = 2, "EI会议"
        elif "ei" in subtype:
            points, name = 3, "EI期刊"
        elif "海报" in subtype or "poster" in subtype:
            points, name = 0.5, "国际会议海报"
        elif "核心" in subtype:
            points, name = 2, "国内核心"
        elif "转载" in subtype or "转摘" in subtype:
            points, name = 1, "转载/转摘"
        elif "国际" in subtype:
            points, name = 1.5, "其它国际会议"
        else:
            return None, ""
        return round(_paper(points, rank, count), 2), f"{name} {points} 分，按作者顺序折算"
    if rule_key == "book":
        if "专著" in subtype:
            points = 10
        elif "编著" in subtype:
            points = 6
        elif "译著" in subtype:
            points = 5
        elif "注释" in subtype or "译文" in subtype:
            points = 2
        else:
            return None, ""
        return round(_book(points, rank, count), 2), f"著作 {points} 分，按责任者顺序折算"
    if rule_key == "project":
        if "独立" in subtype:
            return 3, "独立完成学校正式批复课题 3 分"
        if "主持" in subtype:
            return 1.8, "合作课题主持人 60%"
        if "国家" in subtype:
            return 1, "参与国家级项目 1 分"
        if "教师" in subtype or "参与" in subtype:
            return 0.5, "参与其它项目 0.5 分"
        return None, ""
    if rule_key == "competition":
        points = _competition(str(data.get("award_level") or ""), str(data.get("award_rank") or ""),
                              str(data.get("category") or ""), data.get("team_size"))
        if points is None:
            return None, ""
        return round(points, 2), "竞赛按级别/名次表折算，团队均分"
    if rule_key == "ip":
        if "专利" in subtype:
            points, name = 2, "发明专利"
        elif "软件" in subtype or "著作权" in subtype:
            points, name = 1, "软件著作权"
        else:
            return None, ""
        return round(_ip(points, rank, count), 2), f"{name} {points} 分，按作者顺序公式折算"
    return None, ""


def _context_payload(context: dict) -> dict:
    return {
        "project": context.get("project_name"),
        "component": context.get("component"),
        "rule_key": context.get("rule_key"),
        "item_cap": _number(context.get("score_cap")),
        "claimed_score": _number(context.get("claimed_score")),
        "details": context.get("details"),
        "occurred_on": str(context.get("occurred_on") or ""),
        "evidence": context.get("evidence_names") or "",
        "student_grade": context.get("cohort"),
        "b1_formula": context.get("b1_formula"),
    }


def generate(context: dict) -> dict:
    cap = _number(context.get("score_cap"), 0.0) or 0.0
    claimed = _number(context.get("claimed_score"), 0.0) or 0.0
    rule_key = context.get("rule_key") or "other"
    model = os.getenv("DEEPSEEK_MODEL", "deepseek-chat")
    fallback = {
        "source": "rule",
        "model": "fallback",
        "prompt_version": PROMPT_VERSION,
        "rule_key": rule_key,
        "extracted": {},
        "suggested_score": round(min(claimed, cap), 2),
        "confidence": 0.2,
        "rationale": "AI 初审不可用，仅按单项上限与申报分截断，请人工按细则核定。",
        "raw": "",
    }
    user = "请初审以下加分申报，并按细则给出建议分：\n" + json.dumps(
        _context_payload(context), ensure_ascii=False, default=str)
    try:
        content = _chat([{"role": "system", "content": SYSTEM + "\n\n细则：\n" + RUBRIC},
                         {"role": "user", "content": user}])
        data = _parse(content)
    except AIError as error:
        fallback["rationale"] = f"{error}；仅按单项上限与申报分截断，请人工按细则核定。"
        return fallback

    extracted = {
        "subtype": data.get("subtype"),
        "author_rank": _int(data.get("author_rank")),
        "author_count": _int(data.get("author_count")),
        "team_size": _int(data.get("team_size")),
        "award_level": data.get("award_level"),
        "award_rank": data.get("award_rank"),
        "hours": _number(data.get("hours")),
    }
    suggested = _number(data.get("suggested_score"))
    confidence = _number(data.get("confidence"), 0.5) or 0.5
    rationale = str(data.get("rationale") or "").strip()
    calculated, note = _calculate(rule_key, {**data, **extracted})
    source = "ai"
    if calculated is not None:
        suggested = calculated
        source = "hybrid"
        rationale = (rationale + "；规则复核：" + note).strip("；")
    if suggested is None:
        suggested = min(claimed, cap)
    suggested = max(0.0, min(float(suggested), cap))
    confidence = max(0.0, min(float(confidence), 1.0))
    if not rationale:
        rationale = "按细则与申报信息给出建议，供审核人参考。"
    return {
        "source": source,
        "model": model,
        "prompt_version": PROMPT_VERSION,
        "rule_key": rule_key,
        "extracted": extracted,
        "suggested_score": round(suggested, 2),
        "confidence": round(confidence, 3),
        "rationale": rationale,
        "raw": content[:8000],
    }
