---
name: notify
description: 사용자 PC에 데스크톱 알림(Windows 토스트, macOS 알림 센터, Linux notify-send)을 띄운다. 사용자가 "알림 보내줘", "끝나면 알려줘", "완료되면 알림" 처럼 작업 결과나 이벤트를 알림으로 받고 싶어 할 때, 또는 Claude Code 훅에 알림을 연결해 달라고 할 때 사용한다.
---

# Notify

설치 없이 OS 기본 기능으로 데스크톱 알림을 띄운다.

| OS | 스크립트 | 방식 |
|---|---|---|
| Windows | `scripts/notify.ps1` | WinRT 토스트 (`Windows.UI.Notifications`), Windows PowerShell 5.1 |
| macOS | `scripts/notify.sh` | `osascript display notification` |
| Linux | `scripts/notify.sh` | `notify-send` (libnotify) |

## 바로 보내기

환경 정보의 Platform이 `win32`면 PowerShell 도구로, 그 밖에는 Bash 도구로 실행한다.

```powershell
& "$PWD\.claude\skills\notify\scripts\notify.ps1" -Title "Claude Code" -Message "빌드가 끝났어요"
```

```bash
bash .claude/skills/notify/scripts/notify.sh -Title "Claude Code" -Message "빌드가 끝났어요"
```

- `-Title`은 생략하면 `Claude Code`다. `-Silent`를 주면 소리 없이 띄운다.
- 제목은 짧게, 본문은 한두 문장으로 쓴다. 토큰·비밀번호·메일 본문 같은 민감한 내용은 넣지 않는다.
- Windows 알림의 보낸 앱 이름은 "Windows PowerShell"로 표시된다(등록된 앱 ID를 빌려 쓰기 때문).
- 알림이 안 보이면 집중 모드(방해 금지)나 설정 > 시스템 > 알림에서 Windows PowerShell 알림이 꺼져 있는지 확인하게 한다.

## 훅에 연결하기 (자동 알림)

사용자가 "끝날 때마다 알려줘"처럼 계속 받길 원하면 Claude Code 훅에 등록한다.
어떤 이벤트에 걸지, 저장 위치(전역 `~/.claude/settings.json` / 프로젝트 `.claude/settings.json`)를 사용자에게 확인한 뒤 `update-config` 스킬로 추가한다.

| 이벤트 | 훅 |
|---|---|
| 응답을 마쳤을 때 | `Stop` |
| 권한 승인·입력을 기다릴 때 | `Notification` |
| 특정 도구 실행 후 | `PostToolUse` (`matcher`로 도구 지정) |
| 서브에이전트 완료 | `SubagentStop` |

Windows 예시(경로는 절대 경로로 바꾼다):

```json
{
  "hooks": {
    "Stop": [{ "hooks": [{ "type": "command",
      "command": "powershell -NoProfile -ExecutionPolicy Bypass -File \"C:/path/to/.claude/skills/notify/scripts/notify.ps1\" -Message \"작업이 끝났어요\"" }] }],
    "Notification": [{ "hooks": [{ "type": "command",
      "command": "powershell -NoProfile -ExecutionPolicy Bypass -File \"C:/path/to/.claude/skills/notify/scripts/notify.ps1\" -Message \"승인이 필요해요\"" }] }]
  }
}
```

macOS/Linux는 `bash /abs/path/.claude/skills/notify/scripts/notify.sh -Message "..."`로 바꾼다.
