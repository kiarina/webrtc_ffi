# 0.1.0 を出す

完了条件: 0.1.0 を pub.dev に公開し、Spirits Garden の body の CLI がそれを使う。

## 現状（2026-11-06）

- macOS（arm64）・Linux（Docker、arm64）・Windows（x64）で `dart test` が通り、Chrome 156 とデータ・H.264・Opus を両方向でやりとりできた
- `dart build cli` で AOT の CLI にでき、Windows の DLL は WS2_32・bcrypt・KERNEL32 だけに依存する

## やること

- 実際の使い手で API を確かめる: Spirits Garden の body の CLI を作り、アプリのシグナリング（Trickle ICE、`nerve`）と spirit・console につなぐ。
  使いにくいところを 0.1.0 の前に直す
- aiortc（spirit host）との接続をこのパッケージのテストか道具に入れる（lab では libdatachannel と aiortc で確かめたが、このパッケージの形ではまだ）
- Linux の x64、macOS の x64、Windows の arm64 は未確認
- Android・iOS（NDK・Xcode の組み立て、hook の分岐）は 0.1.0 に入れるか決める
- 公開の前に、名前・版・中身・dry-run の結果をオーナーに見せる。publisher は `kiarina.dev`

## 未検証の懸念

- 受け取りは届いた順のまま（jitter buffer・並べ直しなし）。インターネット越しで順番が入れ替わると `H264Depacketizer` は欠けとして扱う
- `WebRtc.logs` の出し先はプロセスに 1 つ（最後に呼んだ isolate）
- 長時間の接続・多数の接続・切断と再接続の繰り返しは測っていない
