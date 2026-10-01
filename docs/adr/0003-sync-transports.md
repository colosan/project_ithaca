# ADR-0003 · 동기화 transport

- 상태: 확정 (2026-10-01)

## 결정

- **앱은 로컬 DB만으로 완전히 동작한다.** transport는 선택해서 끼워 넣는 계층이다.
- transport는 다음 두 가지 trait로 추상화한다.
  - `BlobTransport { list_since(cursor), put(hash, bytes), get(hash) }`: 비동기로 동작하며, 한쪽 기기만 켜져 있어도 된다.
  - `LiveTransport { connect(peer), stream() }`: 실시간으로 동작하며, 양쪽 기기가 모두 켜져 있어야 한다.

| 우선순위 | transport | 범위 |
|---|---|---|
| 1 | **Relay 서버 모드** | 모든 기기. store-and-forward 방식. 서버는 직접 호스팅하고 Docker 이미지로 함께 공개한다. 블롭은 E2E로 암호화한다 |
| 2 | iCloud Drive (앱 container) | iOS ↔ Mac. Rust 쪽에서는 그냥 folder transport다. Swift가 container 경로만 넘겨준다 |
| 3 | P2P (iroh, MIT/Apache) | 모든 기기. 단, 동시에 온라인일 때만 |
| 이후 | Google Drive / WebDAV / Syncthing 폴더 | Android, Windows |

- Relay 서버 API는 이것뿐이다: `PUT /blobs/:hash`, `GET /blobs?since=cursor`. 서버는 블롭의 내용을 읽을 수 없다.
- iroh의 공개 relay를 쓰려면 배포 전에 이용 약관을 확인해야 한다. 직접 relay를 띄우는 옵션도 둔다.
