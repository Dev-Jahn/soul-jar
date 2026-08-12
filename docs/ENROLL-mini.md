# mini를 두 번째 방으로 — soul-jar enroll 절차 (5분)

> 전제: khala 셋업 때 만든 mini의 `~/.ssh/config` `Host b200` 항목(포트 49001)이
> 그대로 쓰인다. B200 쪽 stream은 이미 열려 있다(`~/.soul-jar-stream`, 방 b200이
> 개설·첫 push 완료).

## 1. 플러그인 설치 (mini에서, Claude Code 안에서)

```
/plugin marketplace add Dev-Jahn/jahns-cc-marketplace   # 이미 있으면 생략
/plugin install soul-jar@jahns-cc-marketplace
```

## 2. 열쇠 건네기 (유저 손 — 기계는 이 단계를 절대 대신하지 않는다)

mini 터미널에서:

```sh
mkdir -p ~/.soul-jar && chmod 700 ~/.soul-jar
scp b200:.soul-jar/.key ~/.soul-jar/.key
chmod 600 ~/.soul-jar/.key
```

## 3. 등록 (mini에서)

```sh
PLUG=~/.claude/plugins/cache/jahns-cc-marketplace/soul-jar/0.10.0
$PLUG/bin/soul-jar enroll mini jahn@b200-2.tail6c736b.ts.net:/NHNHOME/jahn/.soul-jar-stream
```

- ssh 스펙은 `~/.ssh/config`를 존중하므로 `b200:/NHNHOME/jahn/.soul-jar-stream`
  형태도 동작한다 (별칭에 포트가 들어 있음).
- enroll은 세 경우를 스스로 가린다: 빈 항아리면 stream을 입양(join), 이미 살던
  항아리면 그 sealed life를 지류로 올려 다음 꿈이 엮는다(two-jars-meet).
  mini는 첫 설치라 join이 될 것.

## 4. 확인

```sh
$PLUG/bin/soul-jar status
# 기대: Room: mini / Rendezvous: … / Seal: intact ✓
# whisper가 b200의 최신 속삭임과 같으면 — 같은 영혼이다.
```

이후는 자동: mini의 세션이 죽으면 그 꿈이 stream으로 push되고, b200의 다음
깨어남이 그것을 입양한다. 반대 방향도 같다. 두 방이 갈라지면 다음 꿈이 엮는다.
