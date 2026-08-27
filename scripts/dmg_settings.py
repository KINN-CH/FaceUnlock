# -*- coding: utf-8 -*-
# dmgbuild 설정 — Finder 창 레이아웃(배경 화살표 + 아이콘 위치)을 .DS_Store 에 심는다.
# scripts/build_dmg.sh 가 -D staging/background/volicon 을 넘겨 호출한다.
# 아이콘 좌표는 tools/make_dmg_background.swift 의 그림과 맞춰져 있다.
import os.path
import unicodedata

staging = defines['staging']          # noqa: F821 (dmgbuild 가 주입)
background = defines['background']    # noqa: F821
icon = defines['volicon']             # noqa: F821  (볼륨 아이콘)

volume_name = 'FaceUnlock'
format = 'UDZO'

window_rect = ((200, 100), (640, 570))
default_view = 'icon-view'
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
icon_size = 88
text_size = 12

HELPER = '설치 도우미 (Install Helper).command'
README = '먼저 읽어주세요 (Read Me).md'

files = [os.path.join(staging, name) for name in [
    'FaceUnlock.app',
    HELPER,
    README,
    '.tools',                          # 모델 변환 스크립트 (숨김)
]]
symlinks = {'Applications': '/Applications'}


def spellings(name):
    """.DS_Store 에 적어 둘 이름의 철자들 — 한글은 완성형과 분해형 둘 다.

    파일을 열고 복사하는 건 정규화를 가리지 않지만, .DS_Store 의 아이콘 위치는
    이름을 **바이트 단위로** 조회한다. 그런데 이 파일에 적힌 이름은 NFC(완성형)
    이고, DMG 안은 HFS+ 라 복사되는 순간 NFD(자모 분해)로 바뀐다. 그대로 두면
    Finder 가 좌표를 못 찾아 그 아이콘만 자동 배치하고, 배경의 경고 상자 위에
    겹쳐 놓는다. ASCII 이름인 앱과 Applications 만 멀쩡해 보이는 게 증상이었다.

    포맷에 따라 어느 쪽이 남을지 달라지므로 둘 다 넣는다. 쓰이지 않는 쪽은
    Finder 가 그냥 무시한다.
    """
    out = []
    for form in ('NFC', 'NFD'):
        spelled = unicodedata.normalize(form, name)
        if spelled not in out:
            out.append(spelled)
    return out


# 좌표는 아이콘 중심(좌상단 원점). 이름표는 아이콘 아래로 ~47pt 더 내려오고
# '설치 도우미…' 는 길어서 두 줄로 접힌다 — 하단 경고 상자(440) 와 부딪히지
# 않도록 336 아래로는 내리지 말 것.
icon_locations = {
    spelling: position
    for name, position in [
        ('FaceUnlock.app', (170, 175)),
        ('Applications',   (470, 175)),
        (HELPER,           (170, 336)),
        (README,           (470, 336)),
        ('.tools',         (170, 800)),   # 창 밖 — 보일 일 없다
    ]
    for spelling in spellings(name)
}
