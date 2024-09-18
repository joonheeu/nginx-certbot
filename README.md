# Nginx와 Let's Encrypt를 이용한 자동 SSL 인증서 발급 및 갱신

이 프로젝트는 [wmnnd/nginx-certbot](https://github.com/wmnnd/nginx-certbot.git) 저장소를 포크하여 개선한 버전입니다. 원본 프로젝트의 MIT 라이선스를 준수하며, 추가적인 기능과 개선사항을 포함하고 있습니다.

Nginx와 Let's Encrypt를 사용하여 SSL 인증서를 자동으로 발급하고 갱신하는 Docker 기반 솔루션을 제공합니다.

## 주요 기능

- 여러 도메인에 대한 SSL 인증서 자동 발급
- 인증서 자동 갱신
- Nginx 리버스 프록시 설정 자동화
- Docker 네트워크 자동 생성
- 각 도메인에 대한 개별 Nginx 설정 파일 생성

## 사전 요구 사항

- Docker
- Docker Compose

## 사용 방법

1. 이 저장소를 클론합니다:

   ```
   git clone https://github.com/joonheeu/nginx-certbot.git
   cd nginx-certbot
   ```

2. `init-letsencrypt.sh` 스크립트를 실행합니다:

   ```
   sudo ./init-letsencrypt.sh -d example.com,www.example.com -e your-email@example.com
   ```

   옵션 설명:

   - `-d`: SSL 인증서를 발급할 도메인 목록 (쉼표로 구분)
   - `-e`: Let's Encrypt 계정 이메일 주소
   - `-s`: 스테이징 모드 사용 (선택적, 1: 활성화, 0: 비활성화, 기본값: 0)
   - `-r`: RSA 키 크기 (선택적, 기본값: 4096)
   - `-h`: 도움말 표시

3. 스크립트 실행 중 각 도메인에 대해 다음 정보를 입력합니다:

   - 기존 Nginx 설정 파일 덮어쓰기 여부
   - 대상 서비스 준비 여부
   - 대상 서비스가 컨테이너에서 실행 중인지 여부
   - 컨테이너 이름 또는 호스트 IP 및 포트

4. 인증서 발급이 완료되면 Nginx가 자동으로 시작됩니다.

## 스테이징 모드

스테이징 모드는 Let's Encrypt의 테스트 환경을 사용하여 인증서를 발급합니다. 이 모드는 다음과 같은 이점이 있습니다:

- 실제 인증서 발급 과정을 시뮬레이션하여 설정 오류를 안전하게 확인할 수 있습니다.
- Let's Encrypt의 실제 서버에 부하를 주지 않고 테스트할 수 있습니다.
- 실제 환경에서의 속도 제한에 걸리지 않습니다.

스테이징 모드에서 발급된 인증서는 브라우저에서 신뢰하지 않지만, 실제 환경으로 전환하기 전에 모든 설정이 올바른지 확인하는 데 유용합니다.

스테이징 모드를 사용하려면 `-s 1` 옵션을 추가하세요:

## 구조

- `init-letsencrypt.sh`: 초기 설정 스크립트
- `docker-compose.yml`: Docker 서비스 정의
- `data/nginx/`: Nginx 설정 파일 저장 디렉토리 (각 도메인별 설정 파일 포함)
- `data/certbot/`: Let's Encrypt 인증서 및 관련 파일 저장 디렉토리

## 주의사항

- 실제 도메인에서 테스트하기 전에 `-s 1` 옵션을 사용하여 스테이징 환경에서 먼저 테스트하는 것이 좋습니다.
- 이 스크립트는 도메인이 이미 해당 서버를 가리키고 있다고 가정합니다.
- 각 도메인에 대한 Nginx 설정 파일은 `data/nginx/` 디렉토리에 생성됩니다. 필요에 따라 수동으로 수정할 수 있습니다.

## 기여

이 프로젝트에 기여하고 싶으시다면 풀 리퀘스트를 보내주세요. 모든 기여를 환영합니다!

## 라이선스

이 프로젝트는 MIT 라이선스 하에 배포됩니다. 자세한 내용은 [LICENSE](LICENSE) 파일을 참조하세요.
