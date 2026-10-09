# Notion 링크 처리

조사: 2026-10-09. 범위는 Grove의 기존 페이지 하단 / 하위 회의록 저장 위치다.
입력 주소의 해석과 실제 Notion 엔티티 / 접근 권한 확인을 별도 단계로 처리한다.

## 조사 결과

Notion의 현재 Page 객체 `url`은 `https://app.notion.com/p/<title-id>`를 예제로 사용한다.
내부 워크스페이스 주소는 `app.notion.com/p/<workspace>`로 안내한다. 기존 `notion.so`,
공개 `*.notion.site`와 현재 앱 주소를 함께 처리해야 한다. API가 반환한 주소에도 같은
규칙을 적용한다. [Page 객체](https://developers.notion.com/reference/page),
[Sites 도메인](https://www.notion.com/help/manage-your-notion-sites),
[공식 도메인](https://www.notion.com/help/allowlist-ip)

공유 링크의 끝에는 일반적으로 32자리 페이지 ID가 있고 API에는 8-4-4-4-12 형식으로
전달한다. URL만으로 페이지 / 데이터베이스 / 보기의 엔티티 종류나 쓰기 권한을 확정할
수는 없다. [페이지 ID](https://developers.notion.com/guides/data-apis/working-with-page-content),
[페이지 조회](https://developers.notion.com/reference/retrieve-a-page),
[공유 권한](https://www.notion.com/help/sharing-and-permissions)

데이터베이스의 개별 항목도 페이지이며 본문에 하위 페이지를 담을 수 있다. 데이터베이스
자체나 저장된 보기는 다른 엔티티다. MCP의 `?v=` 주소는 데이터베이스를 반환하고
`view://`로 보기를 조회한다. 페이지 항목의 본문에 추가하는 동작을 데이터베이스에
새 행을 만드는 동작과 혼동하지 않는다. [데이터베이스 항목](https://www.notion.com/help/intro-to-databases),
[MCP 엔티티](https://developers.notion.com/guides/mcp/mcp-supported-tools),
[보기 객체](https://developers.notion.com/guides/data-apis/working-with-views)

폼은 데이터베이스와 연결된 입력 / 응답 보기다. 위키에는 Home과 데이터베이스 보기가
공존하므로 화면 이름으로 엔티티를 단정하지 않고 실제 응답 종류를 확인한다.
[폼](https://www.notion.com/help/forms), [위키](https://www.notion.com/help/wikis-and-verified-pages)

Sites는 사용자 도메인 / 슬러그 / 홈페이지 주소를 지원한다. 모든 공개 주소에 페이지 ID가
있는 것은 아니다. Grove는 일반 웹사이트를 직접 열거나 리디렉션을 따라 ID를 추측하지
않는다. ID가 없는 공개 주소는 내부 페이지의 공유 링크를 요청한다.
[게시 슬러그](https://www.notion.com/help/public-pages-and-web-publishing),
[사용자 도메인](https://www.notion.com/help/connect-a-custom-domain-with-notion-sites)

블록 링크는 페이지 내부 위치를 가리킨다. Grove는 본래 페이지를 저장 위치로 사용하고
기존 계약대로 페이지 맨 아래에 추가한다. Notion 앱의 링크 열기 설정과 페이지 식별은
별개다. 설치된 공식 Notion 7.37.1의 URL scheme은 `notion`이며 production 앱 도메인은
`app.notion.com`으로 확인했다. [블록 링크](https://www.notion.com/help/create-links-and-backlinks),
[앱 링크 열기](https://www.notion.com/help/account-settings)

## 지원표

`<id>`는 32자리 16진수 또는 하이픈이 있는 UUID다. 실제 워크스페이스 이름 / 개인 페이지
ID를 예제나 제품 기본값에 넣지 않는다.

| 형식 / 경우 | Grove 처리 |
| --- | --- |
| `https://app.notion.com/p/<workspace>/<id>` | 페이지 ID 후보 추출, 서버에서 페이지 확인 |
| `https://app.notion.com/p/<title>-<id>` 또는 `/p/<id>` | 같은 방식 |
| `https://www.notion.so/<title>-<id>` / `/<workspace>/<id>` | 기존 주소 호환 |
| `https://notion.com/<workspace>/<id>` / `www.notion.com` | 공식 보기 예제의 호스트도 ID 후보로 처리, 서버에서 엔티티 확인 |
| `https://<workspace>.notion.site/<title>-<id>` | ID가 있으면 확인 가능. 공개 여부는 쓰기 권한이 아님 |
| `notion://app.notion.com/p/<id>` / `notion://www.notion.so/<id>` | 앱 열기 전용 scheme을 페이지 후보로 정규화, 앱 실행하지 않음 |
| raw UUID / 32자리 ID | 기존 고급 입력 호환 |
| `source=copy_link`, `v=...`, 일반 추적 쿼리 | 경로의 페이지 ID는 유지. 보기 ID를 페이지 ID로 쓰지 않음 |
| `#<block-id>` | 원래 페이지를 확인. 블록 아래에 저장하지 않음 |
| 데이터베이스 안 개별 페이지 | 서버의 page 응답 / 제목이 확인되면 본문에 하위 페이지 추가 가능 |
| 데이터베이스 / 데이터 소스 / 저장된 보기 / 폴더 | 저장 위치로 거부. 엔티티 종류와 잘못된 URL을 구분 |
| 폼 보기 / 위키의 데이터베이스 루트 | 현재 페이지 본문 저장 범위 밖. 개별 page 엔티티를 선택 |
| `app.notion.com/p/<workspace>` | 페이지 ID가 없는 워크스페이스 홈. 페이지 공유 링크 요청 |
| ID 없는 `*.notion.site/<slug>` / 사이트 홈 / 사용자 도메인 | Notion에서 지원하는 공개 주소지만 MVP 자동 해석 범위 밖. 내부 공유 링크 요청 |
| 경로와 `p` / `peek` 쿼리가 다른 ID를 지시 | 대상이 모호하므로 전체 페이지의 공유 링크 요청 |
| 다른 호스트, userinfo, 비표준 port, http / javascript / file | 페이지 링크로 처리하지 않음 |
| 유사 도메인 / 33자리 ID / 손상된 UUID / 여러 URL | 거부, 유효한 ID의 부분 문자열만 잘라 쓰지 않음 |

## 구현 계약

- `NotionPageLink`가 입력 정규화 / ID 후보 추출 / 오류 분류의 단일 경로다.
- 입력뿐 아니라 MCP가 반환한 페이지 URL과 기존 receipt 복구 링크에도 적용한다.
- 32자리 ID의 문법을 확인하며 UUID 버전 비트를 특정 값으로 강제하지 않는다.
- 서버 응답에서 page ID를 대조한 뒤 페이지 제목과 본문을 확인한다. 데이터베이스
  항목의 제목 키가 반드시 `title`이라는 가정은 하지 않고 명시적인 응답 제목을 사용한다.
- 데이터베이스에 새 행을 넣는 기능은 추가하지 않는다. 직접 공개 사이트 HTML이나
  사용자 도메인을 호출하지 않고, 인증 정보는 기존 공식 REST / MCP endpoint에만 보낸다.
- 입력 실패는 설정 / 내보내기 입력 옆에서 이유와 필요한 복구만 안내한다. 빈 입력에는
  설명을 반복하지 않는다.
- 주소 / 연결을 바꾸면 이전 위치 확인 결과를 표시하지 않는다. 요청 당시 주소와
  연결이 여전히 같은 경우에만 비동기 제목 조회 결과를 반영한다.
- 합성 사례 표와 API 응답 사례로 검증한다. 실제 페이지 변경은 별도 명시적 요청이
  있을 때만 진행하며 조회 성공을 쓰기 권한 / 저장 성공으로 간주하지 않는다.

## 한계 / 확인 기준

Notion의 공개 문서는 URL 라우팅의 완전한 문법을 제공하지 않는다. `p` / `peek`의 모든
의미나 사용자 도메인 → 내부 ID 변환을 보장하는 MCP 계약을 이번 조사에서 확인하지
못했다. 임의 의미를 구현하지 않는다. 페이지 제목이 없는 서버 응답도 성공으로 만들지
않는다. 403 / 404는 연결 / 접근 권한과 존재 여부를 확인할 오류이며 URL 형식 오류와 다르다.

공식 Help / API / MCP 문서 15개, 설치된 공식 앱의 URL scheme / 정적 URL helper를 대조했다.
사용자 제공 링크의 read-only 엔티티 확인은 비공개 인계에만 기록한다. 특정 워크스페이스
상수, 실제 페이지 ID, 계정, 본문과 raw 응답은 제품 Git에 넣지 않는다.
