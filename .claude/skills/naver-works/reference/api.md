# NAVER WORKS API reference

nworks v1.3.1(yjcho9317/nworks)의 `src/api/*`에서 옮긴 엔드포인트와 주의점이다.
모든 경로는 `https://www.worksapis.com/v1.0` 기준이며 `{userId}`는 보통 `me`다.
경로에 넣는 ID는 URL 인코딩한다.

## 목차
- [Scope](#scope)
- [메일](#메일-mail)
- [캘린더](#캘린더-calendar)
- [할 일](#할-일-task)
- [게시판](#게시판-board)
- [드라이브](#드라이브-file)
- [연락처](#연락처-contact)
- [조직 구성원 / 봇 메시지](#조직-구성원--봇-메시지-서비스-계정)

## Scope

| 기능 | 읽기 | 쓰기 |
|---|---|---|
| 메일 | `mail.read` | `mail` |
| 캘린더 | `calendar.read` | `calendar` |
| 할 일 | `task.read` + `user.read` | `task` |
| 게시판 | `board.read` | `board` |
| 드라이브 | `file.read` | `file` |
| 연락처 | `contact.read` | `contact` |
| 봇 (서비스 계정) | `bot.read`, `user.read` | `bot` |

`login -Preset readonly`는 읽기 scope만, `-Preset all`은 전부 요청한다.
403이 나면 대개 scope가 없는 것이다.

## 메일 (mail)

| 작업 | 호출 |
|---|---|
| 목록 | `GET /users/me/mail/mailfolders/{folderId}/children?count=30[&cursor=][&isUnread=true]` — `folderId` 0 = 받은편지함 |
| 읽기 | `GET /users/me/mail/{mailId}` → `{ mail: {from,to,cc,subject,body,...}, attachments: [{attachmentId, filename, size}] }` |
| 첨부 받기 | `attachment /users/me/mail/{mailId}/attachments/{attachmentId} -OutDir <dir>` |
| 보내기 | `POST /users/me/mail` → 202 |

보내기 본문:
```json
{ "to": "a@x.com;b@x.com", "cc": "", "bcc": "", "subject": "제목", "body": "본문", "contentType": "text" }
```
- `to`/`cc`/`bcc`는 문자열이다. 여러 명은 `;`로 구분한다.
- `contentType`은 `html` 또는 `text`다.
- 목록 응답에는 `unreadCount`, `totalCount`, `responseMetaData.nextCursor`가 들어 있다.

## 캘린더 (calendar)

| 작업 | 호출 |
|---|---|
| 목록 | `GET /users/me/calendar/events?fromDateTime={ISO}&untilDateTime={ISO}` → `events[].eventComponents[]` |
| 단건 | `GET /users/me/calendar/events/{eventId}` → `eventComponents[0]` |
| 생성 | `POST /users/me/calendar/events` → 201 |
| 수정 | `PUT /users/me/calendar/events/{eventId}` (전체 교체) |
| 삭제 | `DELETE /users/me/calendar/events/{eventId}?sendNotification=false` → 204 |

생성 본문:
```json
{
  "eventComponents": [{
    "eventId": "event-<새 UUID>",
    "summary": "주간 회의",
    "start": { "dateTime": "2026-10-22T10:00:00", "timeZone": "Asia/Seoul" },
    "end":   { "dateTime": "2026-10-22T11:00:00", "timeZone": "Asia/Seoul" },
    "description": "", "location": "",
    "attendees": [{ "email": "a@x.com", "displayName": "", "partstat": "NEEDS-ACTION", "isOptional": false, "isResource": false }],
    "transparency": "OPAQUE", "visibility": "PUBLIC"
  }],
  "sendNotification": false
}
```
- **`eventId`는 클라이언트가 만든다.** `event-` 뒤에 `[guid]::NewGuid()`를 붙인다.
- `dateTime`에는 **초까지** 넣는다(`HH:mm:ss`). 초가 없으면 API가 거부한다.
- 종일 일정은 `start/end`에 `{ "date": "YYYY-MM-DD" }`를 쓴다.
- **수정은 PUT 전체 교체다.** 먼저 단건을 GET하고, 바꿀 필드만 덮어쓴 eventComponent를 그대로 보낸다.
  빠뜨린 필드(참석자, 설명 등)는 지워진다.
- 목록 쿼리의 `fromDateTime`/`untilDateTime`은 `2026-10-20T00:00:00%2B09:00`처럼 URL 인코딩한다.

## 할 일 (task)

| 작업 | 호출 |
|---|---|
| 카테고리 | `GET /users/me/task-categories` → `taskCategories[]` |
| 목록 | `GET /users/me/tasks?categoryId=default&count=50&status=ALL\|TODO[&cursor=]` |
| 단건 | `GET /tasks/{taskId}` |
| 생성 | `POST /users/me/tasks` → 201 |
| 수정 | `PATCH /tasks/{taskId}` — `{ "title"?, "content"?, "dueDate"?: "YYYY-MM-DD" \| null }` |
| 완료/취소 | `POST /tasks/{taskId}/complete`, `POST /tasks/{taskId}/incomplete` → 204 |
| 삭제 | `DELETE /tasks/{taskId}` → 204 |

생성 본문:
```json
{
  "assignorId": "<내 userId>",
  "assignees": [{ "assigneeId": "<userId>", "status": "TODO" }],
  "title": "제목", "content": "", "completionCondition": "ANY_ONE",
  "dueDate": "2026-10-31", "categoryId": "<선택>"
}
```
- `assignorId`와 `assigneeId`에는 `me`를 쓸 수 없다. `GET /users/me`로 실제 `userId`를 먼저 받는다.

## 게시판 (board)

| 작업 | 호출 |
|---|---|
| 게시판 목록 | `GET /boards?count=20[&cursor=]` |
| 글 목록 | `GET /boards/{boardId}/posts?count=20[&cursor=]` |
| 글 읽기 | `GET /boards/{boardId}/posts/{postId}` |
| 글 쓰기 | `POST /boards/{boardId}/posts` — `{ "title", "body", "enableComment"?: true, "sendNotifications"?: false }` |

- `boardId`와 `postId`는 16자리가 넘는 int64다. 응답 JSON에서 **원문 숫자 문자열 그대로** 쓴다.
  PowerShell `ConvertFrom-Json`이나 JS 숫자로 바꾸면 정밀도가 깨질 수 있다.

## 드라이브 (file)

| 작업 | 호출 |
|---|---|
| 내 드라이브 루트 | `GET /users/me/drive/files?count=20[&cursor=]` |
| 폴더 안 | `GET /users/me/drive/files/{folderId}/children?count=20` |
| 받기 | `download /users/me/drive/files/{fileId}/download -OutDir <dir>` |
| 올리기 | `upload -File <path> [-FolderId <id>] [-Overwrite]` (최대 100MB) |
| 공유 드라이브 목록 | `GET /sharedrives?count=20` → 목록 키가 소문자 **`sharedrives`** |
| 공유 드라이브 파일 | `GET /sharedrives/{sharedriveId}/files[/{folderId}/children]?count=20` |
| 공유 드라이브 받기 | `download /sharedrives/{sharedriveId}/files/{fileId}/download -OutDir <dir>` |

- 다운로드는 302로 스토리지 URL을 준다. `download` 명령은 허용 호스트
  (`*.worksmobile.com`, `worksapis.com`)일 때만 토큰을 실어 따라간다.
  `api`로 직접 부르지 않는다.
- 업로드는 두 단계다. 먼저 `POST .../drive/files[/{folderId}]`에 `{fileName, fileSize, overwrite}`를
  보내 `uploadUrl`을 받고, 그 URL로 multipart(`Filedata`)를 올린다. `upload` 명령이 둘 다 처리한다.

## 연락처 (contact)

| 작업 | 호출 |
|---|---|
| 목록/검색 | `GET /users/me/contacts?count=20[&email=][&telephone=][&contactTagId=][&accessibleRange=ALL\|MEMBER][&cursor=]` |
| 단건 | `GET /contacts/{contactId}` |
| 생성 | `POST /contacts` |
| 수정 | `PATCH /contacts/{contactId}` (부분) · `PUT` (전체) |
| 삭제 | `DELETE /contacts/{contactId}` → 204 |
| 태그 | `GET /users/me/contact-tags?count=20` |

생성 본문 예시:
```json
{
  "contactName": { "lastName": "홍", "firstName": "길동" },
  "emails": [{ "email": "hong@x.com", "primary": true }],
  "telephones": [{ "telephone": "010-0000-0000", "primary": true }],
  "organizations": [{ "name": "회사", "department": "팀", "title": "직책", "primary": true }],
  "memo": ""
}
```
- 이메일, 전화, 소속은 **배열**이다. 응답을 읽을 때 첫 값만 보지 말고 전부 본다.
- `type` 값(회사·휴대폰 등)은 nworks 소스에 정의돼 있지 않다. 필요하면 기존 연락처를 GET해서 쓰는 값을 확인한다.

## 조직 구성원 / 봇 메시지 (서비스 계정)

모두 `bot` 명령으로 부른다. `setup`에 `-ServiceAccount -PrivateKeyPath -BotId`가 필요하다.

| 작업 | 호출 |
|---|---|
| 조직 구성원 | `bot GET "/users?count=100[&cursor=]"` → `users[]: {userId, userName, email, organizations}` |
| 사용자에게 메시지 | `message -To <userId> -Text "..."` |
| 채널에 메시지 | `message -Channel <channelId> -Text "..."` |
| 채널 구성원 | `bot GET /bots/{botId}/channels/{channelId}/members` |
| 버튼/리스트 메시지 | `bot POST /bots/{botId}/users/{userId}/messages -BodyFile f` |

버튼·리스트 메시지 본문:
```json
{ "content": { "type": "button_template", "contentText": "본문", "actions": [ ... ] } }
{ "content": { "type": "list_template", "coverData": { "text": "제목" }, "elements": [ ... ] } }
```
- `actions`와 `elements` 항목 형식은 nworks가 그대로 전달만 한다. NAVER WORKS Bot API 문서의 템플릿 형식을 따른다.
- 봇은 대상 사용자나 채널에 추가돼 있어야 메시지를 보낼 수 있다.
- 봇 토큰 기본 scope는 `bot bot.read user.read`다. 바꾸려면 `$env:NWORKS_SCOPE`를 쓴다.
