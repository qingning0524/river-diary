#!/usr/bin/env python3
"""The 80-glyph River catalog, authored once on a 24x24 grid.

Weight carries meaning:
  current  the body of the glyph
  ripple   evidence, detail, secondary motion

Containers are vessels: they hold a water level and open at 4 o'clock.
"""
from __future__ import annotations

import math

from river_glyph import Glyph, Part, Water, circle_open, container, dot, line, poly, rr, cir

ICONS: list[Glyph] = []


def add(gid: str, label: str, category: str, parts: list[Part], water: Water | None = None,
        nav: bool = False) -> None:
    ICONS.append(Glyph(gid, label, category, parts, water=water, nav=nav))


def rays(cx: float, cy: float, r1: float, r2: float, angles, weight: str = "ripple") -> Part:
    d = []
    for a in angles:
        t = math.radians(a)
        d.append(f"M{cx + r1 * math.cos(t):.2f} {cy + r1 * math.sin(t):.2f}"
                 f"L{cx + r2 * math.cos(t):.2f} {cy + r2 * math.sin(t):.2f}")
    return Part("".join(d), weight)


# ---------------------------------------------------------------- 主导航

river1 = "M15.12 1.92C.48 7.2 22.8 15.6 5.28 22.08"
river2 = "M19.92 1.92C5.28 7.2 27.6 15.6 10.08 22.08"
add("river", "River / 品牌", "主导航", [poly(river1), poly(river2, accent=True)], nav=True)

add("today", "今天", "主导航", [
    Part(circle_open(12, 11.8, 6.3, gap=24, start=30)),
    rays(12, 11.8, 8.2, 9.7, (0, 45, 90, 135, 180, 225, 270, 315)),
], nav=True)

add("footprints", "足迹", "主导航", [
    poly("M15.5 9.2c0 3-4.5 6.8-4.5 6.8S6.5 12.2 6.5 9.2a4.5 4.5 0 0 1 9 0Z"),
    dot(11, 9, 1.25),
    poly("M11 19H7a3 3 0 0 1 0-6", "ripple", accent=True),
    poly("M15.5 19H18a2.5 2.5 0 0 0 0-5", "ripple", accent=True),
    dot(18, 19, 0.95, accent=True),
], nav=True)

p, w = container(4.6, 4.2, 14.8, 16.4, 3.0)
add("confirmations", "待确认", "主导航", [
    *p,
    poly("M8.2 11.4l1.7 1.7 3-3.3", "ripple", accent=True),
    line(14.6, 11.6, 16.4, 11.6),
    line(8.2, 16.6, 16.4, 16.6),
    poly("M9.4 2.6h5.2a1.2 1.2 0 0 1 0 2.4H9.4a1.2 1.2 0 0 1 0-2.4Z", "ripple"),
], water=w, nav=True)

p, w = container(4.0, 6.4, 16.0, 14.0, 3.0)
add("memory", "记忆", "主导航", [
    *p,
    line(5.4, 10.0, 18.6, 10.0),
    line(9.6, 12.8, 14.4, 12.8, "ripple", accent=True),
], water=w, nav=True)

add("review", "回顾", "主导航", [
    poly("M5.4 7.2a8 8 0 1 1-1.1 9.6"),
    poly("M5.4 3.2v4H1.4", "ripple", accent=True),
    poly("M12 7.6v4.6l3.1 1.9", "ripple"),
], nav=True)

add("profile", "我的", "主导航", [
    Part(circle_open(12, 7.4, 3.8, gap=26, start=30)),
    poly("M4.6 21.2v-1.8a7.4 7.4 0 0 1 14.8 0v1.8"),
], nav=True)

add("timeline", "时间线", "主导航", [
    line(6, 3.4, 6, 20.8, "current"),
    dot(6, 6.4, 1.9),
    dot(6, 17.2, 1.9, accent=True),
    poly("M11 5.6h8.4M11 9.2h5.2M11 16.4h8.4M11 20h5.2", "ripple"),
], nav=True)

# ---------------------------------------------------------------- 记录工具

add("journal", "日记", "记录工具", [
    poly("M12 5.4C8.1 2.9 4.6 3.1 3.1 4v15c2.9-1 6.2-.7 8.9 1 2.7-1.7 6-2 8.9-1V4c-1.5-.9-5-1.1-8.9 1.4Z"),
    line(12, 5.4, 12, 20.2),
    poly("M6.2 7.6l3 .8M15.1 8.4l3-.8", "ripple"),
])

add("edit", "编辑", "记录工具", [
    poly("m15.4 4.2 4.4 4.4M4.4 19.6l1.1-4.8L16.4 3.9a1.6 1.6 0 0 1 2.3 0l1.6 1.6a1.6 1.6 0 0 1 0 2.3L9.2 18.5Z"),
    line(4.4, 19.6, 9.2, 18.5, "ripple", accent=True),
])

p, w = container(4.0, 3.4, 16.0, 17.2, 2.8, water=False)
add("quick-note", "随手记", "记录工具", [
    *p,
    poly("M14.4 3.4v5.2H20", "ripple"),
    poly("M12 11.6v6M9 14.6h6", "ripple", accent=True),
])

p, w = container(3.6, 5.0, 16.8, 16.0, 3.0)
add("calendar", "日期", "记录工具", [
    *p,
    line(3.6, 10.2, 20.4, 10.2),
    poly("M8 2.8v4M16 2.8v4", "ripple"),
    dot(8, 13.0, 1.1),
    dot(12, 13.0, 1.1, accent=True),
    dot(16, 13.0, 1.1),
    dot(8, 17.0, 1.1),
    dot(12, 17.0, 1.1),
], water=w)

add("search", "搜索", "记录工具", [
    Part(circle_open(10.6, 10.4, 6.2, gap=24, start=30)),
    poly("M15.4 15.4 21 21"),
])

add("filter", "筛选", "记录工具", [
    poly("M3.8 4.6h16.4l-6.2 7.2v6.3l-4 2.1v-8.4Z"),
    line(9.6, 9.4, 14.4, 9.4, "ripple", accent=True),
])

add("bookmark", "收藏", "记录工具", [
    poly("M6.2 20.8V5.4a2.2 2.2 0 0 1 2.2-2.2h7.2a2.2 2.2 0 0 1 2.2 2.2v15.4l-5.8-3.9Z"),
])

add("tag", "标签", "记录工具", [
    poly("M13 3.2H4.4v8.6l7.5 7.5a2 2 0 0 0 2.8 0l5.9-5.9a2 2 0 0 0 0-2.8Z"),
    dot(8.2, 7, 1.25, accent=True),
])

# ---------------------------------------------------------------- AI 与故事

add("insight", "洞察", "AI与故事", [
    poly("M8.4 15.4a6 6 0 1 1 7.2 0v2.4H8.4Z"),
    poly("M9.2 20.8h5.6M9 17.8h6", "ripple"),
    line(12, 7.4, 12, 11.6, "ripple", accent=True),
])

add("understanding", "我的理解", "AI与故事", [
    Part(cir(8.9, 12, 4.5)),
    Part(cir(15.1, 12, 4.5), accent=True),
    dot(12, 12, 1.1),
])

p, w = container(3.6, 4.4, 16.8, 12.4, 3.2)
add("chat", "对话", "AI与故事", [
    *p,
    poly("M8 16.8 6.6 21l4.6-2.6", "ripple"),
    dot(8, 10.6, 0.9),
    dot(12, 10.6, 0.9, accent=True),
    dot(16, 10.6, 0.9),
], water=w)

add("reunion", "记忆重逢", "AI与故事", [
    poly("M5.4 7.2a8 8 0 1 1-1.1 9.6"),
    poly("M5.4 3.2v4H1.4", "ripple", accent=True),
    poly("M12 8.2c-3-3-6.4 1.1-3.2 4.1l3.2 3.1 3.2-3.1c3.2-3-.2-7.1-3.2-4.1Z", "ripple", accent=True),
])

p, w = container(4.4, 3.4, 15.2, 17.2, 2.8)
add("chapter", "人生章节", "AI与故事", [
    *p,
    line(8.6, 3.4, 8.6, 20.6, "ripple"),
    line(11.8, 9.2, 16.4, 9.2, "ripple", accent=True),
    line(11.8, 13.2, 16.4, 13.2, "ripple"),
    line(11.8, 17.2, 14.6, 17.2, "ripple"),
], water=w)

p, w = container(3.4, 4.4, 17.2, 14.4, 3.0, water=False)
add("replay", "故事回放", "AI与故事", [
    *p,
    line(3.4, 8.4, 20.6, 8.4),
    poly("M9.8 11.2l5.4 3.4-5.4 3.4Z", "ripple", accent=True),
])

p, w = container(3.4, 7.6, 17.2, 13.0, 2.8)
add("future-letter", "未来来信", "AI与故事", [
    *p,
    poly("m3.4 8.6 8.6 6.4 8.6-6.4", "ripple"),
    poly("M12 2.2v5M9.8 4.4 12 2.2l2.2 2.2", "ripple", accent=True),
], water=w)

add("experiment", "生活小实验", "AI与故事", [
    poly("M9 3.2h6M10 3.2v5.8l-5.6 9.2a1.5 1.5 0 0 0 1.3 2.3h12.6a1.5 1.5 0 0 0 1.3-2.3L14 9V3.2"),
    line(7.8, 15.6, 16.2, 15.6, "ripple", accent=True),
    dot(10.4, 17.6, 0.8),
    dot(13.6, 18.6, 0.8, accent=True),
])

# ---------------------------------------------------------------- 生活来源

add("health", "健康", "生活来源", [
    poly("M12 20 4 12C-2 5 7 0 12 6c5-6 14-1 8 6Z"),
    poly("M6 12h3l2-4 2 8 2-4h3", "ripple", accent=True),
])

add("sleep", "睡眠", "生活来源", [
    poly("M20 15a8 8 0 0 1-11-11 8 8 0 1 0 11 11Z"),
    poly("M17 3v4M15 5h4", "ripple", accent=True),
])

add("steps", "步数", "生活来源", [
    poly("M4 19.4h4.4v-4.4H13V10.6h4.4V6.2"),
    dot(19, 4.6, 1.35, accent=True),
])

add("movement", "运动", "生活来源", [
    Part(rr(2.6, 8.6, 3.6, 6.8, 1.3)),
    Part(rr(17.8, 8.6, 3.6, 6.8, 1.3)),
    Part(rr(6.9, 7.4, 2.7, 9.2, 1.1), "ripple", accent=True),
    Part(rr(14.4, 7.4, 2.7, 9.2, 1.1), "ripple", accent=True),
    line(6.2, 12, 17.8, 12),
])

add("location", "地点", "生活来源", [
    poly("M19 9.2c0 4.8-7 11.4-7 11.4S5 14 5 9.2a7 7 0 1 1 14 0Z"),
    Part(cir(12, 9.2, 2.4), "ripple"),
    dot(12, 9.2, 0.95, accent=True),
])

add("map", "地图", "生活来源", [
    poly("m3.2 6.4 5.6-2.8 6.4 2.8 5.6-2.8v14.4l-5.6 2.8-6.4-2.8-5.6 2.8Z"),
    poly("M8.8 3.6v14.4M15.2 6.4v14.4", "ripple", accent=True),
])

p, w = container(3.4, 3.4, 17.2, 17.2, 3.2, water=False)
add("photo", "照片", "生活来源", [
    *p,
    Part(cir(8.6, 8.8, 1.9), "ripple", accent=True),
    poly("M4.8 17.2 9.4 12.6l3.5 3.6 3.8-5.2 3.6 4.8", "ripple", accent=True),
])

add("microphone", "语音", "生活来源", [
    Part(rr(9.2, 2.6, 5.6, 12.6, 2.8)),
    poly("M5.6 10.6v1.8a6.4 6.4 0 0 0 12.8 0v-1.8", "ripple", accent=True),
    poly("M12 18.8V22M8.4 22h7.2", "ripple"),
])

# ---------------------------------------------------------------- 连接与同步

add("activity", "活动", "连接与同步", [
    poly("M3 12h4l3-8 4 16 3-8h4", "ripple", accent=True),
])

p, w = container(2.8, 4.6, 18.4, 12.2, 2.6)
add("desktop", "Mac", "连接与同步", [
    *p,
    poly("M8.8 21h6.4M12 16.8V21", "ripple"),
], water=w)

p, w = container(5.8, 2.8, 12.4, 18.4, 2.8)
add("phone", "iPhone", "连接与同步", [
    *p,
    line(10.2, 5.6, 13.8, 5.6, "ripple"),
    dot(12, 18.2, 0.8),
], water=w)

add("link", "连接", "连接与同步", [
    poly("M9.6 14.4l-1 1a3.2 3.2 0 1 1-4.5-4.5l4-4a3.2 3.2 0 0 1 4.5 0"),
    poly("M14.4 9.6l1-1a3.2 3.2 0 1 1 4.5 4.5l-4 4a3.2 3.2 0 0 1-4.5 0"),
    line(9.2, 14.8, 14.8, 9.2, "ripple", accent=True),
])

add("sync", "同步", "连接与同步", [
    poly("M20 8a8 8 0 0 0-13-4L4 7M4 3v4h4"),
    poly("M4 16a8 8 0 0 0 13 4l3-3M20 21v-4h-4", accent=True),
])

add("cloud", "云端档案", "连接与同步", [
    poly("M6.4 18C3.8 18 2.2 16.3 2.2 14s1.8-4 4-4c0-3.8 2.5-6 6-6 3.1 0 5.4 2.1 6 5 2.3.2 3.9 1.9 3.9 4.5 0 2.8-1.8 4.5-4.5 4.5Z"),
    poly("M7.6 14.6h8.8", "ripple", accent=True),
])

add("backup", "备份", "连接与同步", [
    poly("M6.4 18C3.8 18 2.2 16.3 2.2 14s1.8-4 4-4c0-3.8 2.5-6 6-6 3.1 0 5.4 2.1 6 5 2.3.2 3.9 1.9 3.9 4.5 0 2.8-1.8 4.5-4.5 4.5"),
    poly("M12 21v-8M9 16l3-3 3 3", "ripple", accent=True),
])

add("restore", "恢复", "连接与同步", [
    poly("M5.4 7.2a8 8 0 1 1-1.1 9.6"),
    poly("M5.4 3.2v4H1.4", "ripple", accent=True),
    poly("M12 8v8M9 13l3 3 3-3", "ripple"),
])

# ---------------------------------------------------------------- 隐私与设置

add("export", "导出", "隐私与设置", [
    poly("M9 4.4H5.4a2 2 0 0 0-2 2v13.2a2 2 0 0 0 2 2h13.2a2 2 0 0 0 2-2V16"),
    poly("M12 3.2h8.8v8.8M20.8 3.2 10.4 13.6", "ripple", accent=True),
])

add("share", "分享", "隐私与设置", [
    poly("M5.2 13.4v5.2a2 2 0 0 0 2 2h9.6a2 2 0 0 0 2-2v-5.2"),
    poly("M12 15.6V2.4M8 5.8l4-3.4 4 3.4", "ripple", accent=True),
])

add("privacy", "隐私", "隐私与设置", [
    poly("M12 2.4 4 5.4v6c0 5 8 10.8 8 10.8s8-5.8 8-10.8v-6Z"),
    dot(12, 10, 1.35, accent=True),
    line(12, 11.3, 12, 14.2, "ripple", accent=True),
])

add("lock", "应用锁", "隐私与设置", [
    Part(rr(5.2, 10.2, 13.6, 11.0, 2.8)),
    poly("M8.4 10.2V7.3a3.6 3.6 0 0 1 7.2 0v2.9"),
    dot(12, 15.2, 1.05, accent=True),
    line(12, 16.1, 12, 18.0, "ripple", accent=True),
])

add("key", "密钥", "隐私与设置", [
    Part(cir(7.4, 8.6, 4.6)),
    line(12, 8.6, 21, 8.6),
    poly("M15.6 8.6v3M18.6 8.6v2.6", "ripple", accent=True),
    dot(7.4, 8.6, 1.0, accent=True),
])

add("shield", "资料保护", "隐私与设置", [
    poly("M12 2.4 4 5.4v6c0 5 8 10.8 8 10.8s8-5.8 8-10.8v-6Z"),
    poly("m8 11.4 3 3 5-6", "ripple", accent=True),
])

add("settings", "设置", "隐私与设置", [
    poly("m10.2 2.8.7-1h2.2l.7 3 1.9.8 2.6-.8 1.1 1.9-2 2.2v2l2 2.2-1.1 1.9-2.6-.8-1.9.8-.7 3h-2.2l-.7-3-1.9-.8-2.6.8-1.1-1.9 2-2.2v-2l-2-2.2 1.1-1.9 2.6.8 1.9-.8Z"),
    Part(cir(12, 12, 3.2), "ripple"),
])

add("appearance", "外观", "隐私与设置", [
    Part("M12 3a9 9 0 0 1 0 18Z", fill=True, opacity=0.28),
    Part(cir(12, 12, 9)),
])

# ---------------------------------------------------------------- 状态与账号

add("notifications", "提醒", "状态与账号", [
    poly("M5 17.2h14l-2.2-3V9a4.8 4.8 0 0 0-9.6 0v5.2Z"),
    poly("M10 20.6h4M12 2.4v2", "ripple", accent=True),
])

p, w = container(3.4, 4.4, 17.2, 15.2, 3.0)
add("account", "账号", "状态与账号", [
    *p,
    Part(cir(9, 9, 2.0), "ripple"),
    poly("M5.8 15.4a3.2 3.2 0 0 1 6.4 0", "ripple"),
    poly("M15 9.2h3.2M15 12.8h3.2", "ripple", accent=True),
], water=w)

add("logout", "退出", "状态与账号", [
    poly("M10 4.2H5.2a2 2 0 0 0-2 2v11.6a2 2 0 0 0 2 2H10"),
    poly("M9 12h12M17 8l4 4-4 4", "ripple", accent=True),
])

add("help", "帮助", "状态与账号", [
    Part(cir(12, 12, 9)),
    poly("M9.4 8.8a2.7 2.7 0 1 1 4.1 2.4c-1.1.6-1.5 1.2-1.5 2.4", "ripple", accent=True),
    dot(12, 17.2, 0.95, accent=True),
])

add("success", "成功", "状态与账号", [
    Part(cir(12, 12, 9)),
    poly("m7.6 12 3 3 5.8-6.2", "ripple", accent=True),
])

add("warning", "警告", "状态与账号", [
    poly("m10.3 3.4-8 14a2 2 0 0 0 1.7 3.1h16a2 2 0 0 0 1.7-3.1l-8-14a2 2 0 0 0-3.4 0Z"),
    line(12, 8.2, 12, 13.2, "ripple", accent=True),
    dot(12, 16.6, 0.9, accent=True),
])

add("error", "失败", "状态与账号", [
    Part(cir(12, 12, 9)),
    poly("m9 9 6 6M15 9l-6 6", "ripple", accent=True),
])

add("info", "信息", "状态与账号", [
    Part(cir(12, 12, 9)),
    line(12, 11, 12, 17, "ripple", accent=True),
    dot(12, 7.4, 0.9, accent=True),
])

# ---------------------------------------------------------------- 基础操作

add("add", "新增", "基础操作", [poly("M12 4.4v15.2M4.4 12h15.2", "ripple", accent=True)])
add("close", "关闭", "基础操作", [poly("m5.6 5.6 12.8 12.8M18.4 5.6 5.6 18.4")])
add("back", "返回", "基础操作", [poly("m14.4 4.6-7.4 7.4 7.4 7.4")])
add("forward", "前往", "基础操作", [poly("m9.6 4.6 7.4 7.4-7.4 7.4")])
add("expand", "展开", "基础操作", [poly("M4 10V4h6M14 4h6v6M20 14v6h-6M10 20H4v-6")])
add("send", "发送", "基础操作", [
    poly("M21 3 3 10.2l7.8 2.8 2.8 7.8Z"),
    line(10.8, 13, 21, 3, "ripple", accent=True),
])
add("play", "播放", "基础操作", [poly("M7.4 3.6 20.6 12 7.4 20.4Z", "ripple", accent=True)])
add("pause", "暂停", "基础操作", [
    Part(rr(5.2, 4.2, 4.2, 15.6, 1.6)),
    Part(rr(14.6, 4.2, 4.2, 15.6, 1.6)),
])

# ---------------------------------------------------------------- 常用操作

add("trash", "删除", "常用操作", [
    poly("M5.2 7.2h13.6l-1 13.4H6.2Z"),
    poly("M3.2 7.2h17.6M9 3.4h6l1 3.8", "ripple"),
    poly("M9.2 11.2v5.8M14.8 11.2v5.8", "ripple", accent=True),
])

add("undo", "撤销", "常用操作", [
    poly("M4 4.8v6h6M4 10.8l3-3a7 7 0 1 1 0 10", "ripple", accent=True),
])

add("copy", "复制", "常用操作", [
    Part(rr(8.2, 8.2, 12.6, 12.6, 2.6), "ripple"),
    poly("M15.8 4.6V2.8H2.8v13h1.8", "ripple"),
])

add("refresh", "刷新", "常用操作", [
    poly("M20 8a8 8 0 1 0 0 8M20 3.2v5h-5", "ripple", accent=True),
])

add("eye", "显示", "常用操作", [
    poly("M2.4 12s3.5-6.8 9.6-6.8S21.6 12 21.6 12s-3.5 6.8-9.6 6.8S2.4 12 2.4 12Z"),
    Part(cir(12, 12, 3.1), "ripple", accent=True),
    dot(12, 12, 0.9, accent=True),
])

add("eye-off", "隐藏", "常用操作", [
    poly("M4.6 7.4A13.5 13.5 0 0 0 2.4 12s3.5 6.8 9.6 6.8a12 12 0 0 0 4.6-1M9.2 5.4a12 12 0 0 1 2.8-.2c6.1 0 9.6 6.8 9.6 6.8a15 15 0 0 1-2.4 3.2M10.2 10a2.9 2.9 0 0 0 3.8 3.8"),
    poly("M3.4 3.4 20.6 20.6", "ripple", accent=True),
])

add("download", "下载", "常用操作", [
    poly("M4 16.2v4.2h16v-4.2"),
    poly("M12 3v12.4M7.2 10.8 12 15.6l4.8-4.8", "ripple", accent=True),
])

p, w = container(4.4, 3.2, 15.2, 17.6, 2.8)
add("context-pack", "上下文包", "常用操作", [
    *p,
    poly("M14.4 3.2v5H20", "ripple"),
    line(7.6, 11.6, 14.4, 11.6, "ripple"),
    line(7.6, 15.4, 11.4, 15.4, "ripple"),
    poly("M18.4 12.6v5.2M15.8 15.2h5.2", "ripple", accent=True),
], water=w)

# ---------------------------------------------------------------- 功能扩展

add("habit", "习惯", "功能扩展", [
    line(12, 21, 12, 9.4),
    poly("M12 14.4c-4.6 0-6.4-3-6.4-6.4 4.6 0 6.4 2.6 6.4 6.4Z", "ripple"),
    poly("M12 11.2c4.6 0 6.4-2.8 6.4-6.2-4.6 0-6.4 2.4-6.4 6.2Z", "ripple", accent=True),
    line(8.4, 20.8, 15.6, 20.8, "ripple"),
])

add("goal", "目标", "功能扩展", [
    Part(cir(12, 12, 9)),
    Part(cir(12, 12, 5.1), "ripple"),
    poly("m12 12 8-8M17.2 4h2.8v2.8", "ripple", accent=True),
])

add("progress", "进展", "功能扩展", [
    poly("M4 3.4v17.2h16.4"),
    poly("m7.2 15.2 4.2-4.4 3.2 2.2 6.2-7.2", "ripple", accent=True),
    dot(20.8, 5.8, 1.1, accent=True),
])

add("database", "资料库", "功能扩展", [
    poly("M3 6.2v11.6c0 2 4 4 9 4s9-2 9-4V6.2"),
    poly("M3 6.2c0-2 4-3.6 9-3.6s9 1.6 9 3.6-4 3.6-9 3.6-9-1.6-9-3.6Z", "ripple"),
    poly("M3 12.2c0 2 4 3.6 9 3.6s9-1.6 9-3.6", "ripple", accent=True),
])

add("source", "记录来源", "功能扩展", [
    Part(cir(12, 12, 3.0)),
    Part(cir(4.6, 5.2, 2.0)),
    Part(cir(19.4, 5.2, 2.0)),
    Part(cir(12, 19.6, 1.7), accent=True),
    poly("m6.2 6.6 3.8 3.2M14 9.8l3.8-3.2M12 15v2.8", "ripple", accent=True),
])

add("evidence", "原始依据", "功能扩展", [
    poly("M13 3.2H4.4v17.6h12.2V7Z"),
    poly("M13 3.2v3.8h3.6M7.4 8.4h3.2M7.4 12.4h3.2M7.4 16.4h3.2", "ripple"),
    Part(circle_open(17.2, 15.4, 3.0, gap=24, start=30), "ripple"),
    line(19.4, 17.6, 21.4, 19.6, "ripple", accent=True),
])

add("more", "更多", "功能扩展", [
    dot(5, 12, 1.25), dot(12, 12, 1.25, accent=True), dot(19, 12, 1.25),
])

add("chevron-down", "下拉", "功能扩展", [poly("m4.8 9 7.2 7.2L19.2 9")])

assert len(ICONS) == 80, len(ICONS)
assert len({i.id for i in ICONS}) == 80
