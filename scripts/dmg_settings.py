# -*- coding: utf-8 -*-
# dmgbuild 설정 — Finder 창 레이아웃(배경 화살표 + 아이콘 위치)을 .DS_Store 에 심는다.
# scripts/build_dmg.sh 가 -D staging/background/volicon 을 넘겨 호출한다.
# 아이콘 좌표는 tools/make_dmg_background.swift 의 그림과 맞춰져 있다.
import os.path

staging = defines['staging']          # noqa: F821 (dmgbuild 가 주입)
background = defines['background']    # noqa: F821
icon = defines['volicon']             # noqa: F821  (볼륨 아이콘)

volume_name = 'FaceUnlock'
format = 'UDZO'

window_rect = ((200, 120), (640, 400))
default_view = 'icon-view'
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
icon_size = 88
text_size = 12

files = [os.path.join(staging, name) for name in [
    'FaceUnlock.app',
    '설치 도우미.command',
    '먼저 읽어주세요.md',
    '.tools',                          # 모델 변환 스크립트 (숨김)
]]
symlinks = {'Applications': '/Applications'}

icon_locations = {
    'FaceUnlock.app':      (170, 185),
    'Applications':        (470, 185),
    '설치 도우미.command':   (320, 330),
    '먼저 읽어주세요.md':    (560, 330),
    '.tools':              (170, 600),  # 창 밖 — 보일 일 없다
}
