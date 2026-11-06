# AGENTS.md

このリポジトリで作業するエージェント向けのガイドラインです。

## 作業前に読むもの

- `README.md`（公開向けの説明。API・対応表・使い方）
- `lib/webrtc_ffi.dart` と `lib/src/`（Dart の契約。ここが正典）
- `native/shim.c`（C の層。イベントの種類は `lib/src/native.dart` の `Ev` と同じ番号に保つ）
- `tasks/`（残っている作業。1 タスク 1 ファイル）
- `CHANGELOG.md`

実証の来歴は labs の `2026/11/06/dart-cli-webrtc-datachannel`（Flutter なしの Dart から libdatachannel を FFI で呼べると確かめた lab。webrtc_dart との比較、
Chrome・aiortc との接続、Docker のコンテナから）。この repo はそれをもとに作り（2026-11-06）、以後はここが所有する。lab とは同期しない。
最初の利用者は Spirits Garden の body の CLI と Docker の body（spirits-garden の `tasks/docker-body.md`）。

## 設計の決まり

- Flutter に依存しない Dart のパッケージ。Flutter のアプリからも使えるが、アプリの映像と音声は flutter_webrtc の担当で、こちらは RTP までを運ぶ。
  取得・エンコード・デコード・再生は持たない
- ネイティブはすべてソースから build hook（`hook/build.dart`）で作り、1 つの共有ライブラリ `webrtc_ffi` にする。実行時に何も入れなくてよいことを保つ
  （OpenSSL ではなく Mbed TLS、Windows は C ランタイムを静的リンク）。書き出す記号は C の API だけ（Mbed TLS・libsrtp を外に見せない）
- ネイティブからのイベントは、接続を作った isolate の port へ `Dart_PostCObject` で送る（`native/shim.c`）。Dart のコードを libdatachannel のスレッドで動かさない。
  `NativeCallable.listener` を 1 つ持つ形は、`dart test` のように複数の isolate が同じプロセスで使うと、終わった isolate を呼んで落ちたのでやめた（2026-11-06）
- メッセージの中身はイベントに載せず、available を受けて `rtcReceiveMessage` で取り出す。構造体を受ける C の関数は shim で包み、Dart は構造体の配置に依存しない
- 生きている `PeerConnection` があれば isolate を終わらせない（`Runtime.retain`）。`dispose()` で放す
- 自動交渉（既定）では、トラックを足したあとも自動で offer を出す（libdatachannel はデータチャネルのときしか出さない）。同じ描画の中で足したトラックは 1 つの offer にまとめる
- SSRC の無いトラック（受けるだけ）は `m=` の記述を Dart で組んで `rtcAddTrack` に渡す。`rtcAddTrackEx` は `a=ssrc:0` を書き、libwebrtc が受け付けない。
  cname（`name`）を省いたときも `a=ssrc:<n>` だけの行になって受け付けないので、shim が既定の cname を入れる
- 受け取りの組み立て（`H264Depacketizer`・`AudioDepacketizer`）は Dart で持つ。libdatachannel の C の API に depacketizer が無いため。並べ直しと jitter buffer は持たない
- 依存の版は `tool/vendor.sh` の 1 か所で決める。上げたら `third_party/VERSIONS.txt`・`THIRD_PARTY_NOTICES.md`・`native/cmake/MbedTLSConfig.cmake` の版を合わせる。
  Mbed TLS は 3 系（libdatachannel 0.24 が `MbedTLS 3` を求める）
- Windows の build は TEMP の下の短いフォルダで行う（MSBuild のパスの上限）。CMake は PATH に無ければ Visual Studio に付いているものを使う（hook の環境変数は絞られているので、
  cl.exe の場所か vswhere の決まった場所から探す）。引数のディレクトリの末尾に `\` を付けない（引用符がずれる）
- 認証値・個人環境のパス・ホスト名を公開物に混ぜない

## 検証

- `dart analyze` と `dart test`（同じプロセスの 2 つの接続で、データチャネルとメディア）
- `dart run tool/interop/chrome.dart`（headless の Chrome と。データ、Chrome の偽カメラ・マイクの H.264・Opus を受け、同じフレームを送り返して Chrome がデコードしたら合格）
- Linux は `tool/docker/Dockerfile`。コンテナの中の Dart と Mac の Chrome をつなぐなら `--host 127.0.0.1 --port <n>` で起こし、Mac の Chrome に `--use-fake-ui-for-media-stream` を付けて開く
- Windows は別の PC へ送って `dart test` と `tool/interop/chrome.dart`（手順はユーザーの環境のもので、ここには書かない）
- README の対応表には、実際に確かめた OS だけを書く

## 公開

pub.dev への公開は取り消せない（discontinue しかできない）。公開の前に名前・版・公開内容・対応範囲をオーナーに示し、`dart pub publish --dry-run` の結果を見せる。
**`.pubignore` があると `.gitignore` は見られない**ので、build の生成物も `.pubignore` に書く。公開したら commit に `git tag -a v<版> -m "webrtc_ffi <版>"` を打って push する。
