# Account Abstraction + Paymaster + Passkey 実装メモ

## 概要

OP Sepolia 上で、以下の構成による AA フローを実装・検証した。

- Smart Account
- laneKey ベースの validator aggregator
- PasskeyValidator
- ContextObservatoryLaneValidator
- ContextObservatoryPaymaster
- Pimlico bundler
- EntryPoint v0.7

最終的に、**estimate → final sign → send** の一連の流れが通る状態まで到達した。

---

## 最終的に安定した送信フロー

### 1. estimate 用 UserOp を作る

estimate 用は、最終送信と分ける。

- paymaster は **MODE_ESTIMATE**
- passkey signature は **dummy だが ABI 的に正しい形**
- prefund は paymaster に持たせる
- gas estimate 用なので、ここでは final の厳密な署名検証は行わない

### 2. bundler で gas estimate

`eth_estimateUserOperationGas` を実行する。

この時点で得るもの:

- `callGasLimit`
- `verificationGasLimit`
- `preVerificationGas`

### 3. final 用 UserOp を作る

final では以下を使う。

- paymaster は **MODE_FINAL**
- paymasterData は **final 用署名**
- gas は署名対象にせず **cap** として扱う
- 最後に passkey の本物の署名を付与する

### 4. final 署名前に roundtrip decode

フロントで生成した passkey signature を、送信前に自分で decode し直して検証する。

確認項目:

- `credHash`
- `authenticatorData`
- `clientDataJSON`
- `challengeIndex`
- `typeIndex`
- `r`
- `s`

### 5. `eth_sendUserOperation`

ここで最終送信する。

---

# 主要な修正点

## 1. Paymaster を 2 モードに分離

### 導入したモード

- `MODE_ESTIMATE`
- `MODE_FINAL`

### 意図

estimate と final では要求が違うため、責務を分けた。

#### MODE_ESTIMATE

- gas estimate を通すためのモード
- prefund を肩代わりする
- postOp は不要
- context は空で返す

#### MODE_FINAL

- 本番送信用モード
- paymaster 認可を行う
- gas は cap として検証
- 必要であれば postOp を使う

---

## 2. final の paymaster 署名対象から gas 系を外した

### 以前の問題

`reqHash` に以下を含めていた。

- `accountGasLimits`
- `preVerificationGas`
- `gasFees`

これにより、bundler 側の内部 pack や gas 解釈差で `BadSignature()` になりやすかった。

### 修正後

final の署名対象は以下に限定した。

- `chainId`
- `address(this)`
- `sender`
- `nonce`
- `keccak256(callData)`
- `validUntil`
- `validAfter`

### gas 系の扱い

gas 系は署名対象ではなく、**cap 上限として別検証**する形に変更した。

---

## 3. gas は cap で管理

final モードでは、以下を cap として paymasterData に入れる。

- `maxVerificationGas`
- `maxCallGas`
- `maxPreVerificationGas`
- `maxMaxPriorityFeePerGas`
- `maxMaxFeePerGas`

onchain では、以下のように上限チェックを行う。

- `verificationGasLimit <= maxVerificationGas`
- `callGasLimit <= maxCallGas`
- `preVerificationGas <= maxPreVerificationGas`
- `maxPriorityFeePerGas <= maxMaxPriorityFeePerGas`
- `maxFeePerGas <= maxMaxFeePerGas`

これにより、厳密一致ではなく「許容範囲内か」で制御できるようになった。

---

## 4. passkey signature の ABI 形式を修正

### 問題

フロント側で生成した signature の ABI 形が、Solidity 側の

```solidity
abi.decode(userOp.signature, (WebAuthn.WebAuthnAuth, bytes32))
```

と一致していなかった。

その結果、以下を引いた。

- `AA23 reverted 0x`
- `AA24 signature error`
- `panic: memory allocation error (0x41)`

### 修正後の ABI

フロント側を以下に統一した。

```ts
"(bytes authenticatorData,string clientDataJSON,uint256 challengeIndex,uint256 typeIndex,bytes32 r,bytes32 s),bytes32";
```

### 注意点

- `((...),bytes32)` のように外側を余計に tuple にしない
- Solidity 側 decode と完全一致させる

---

## 5. dummy signature も本物と同じ ABI に統一

estimate 用 dummy signature も、本物と同じ ABI 形に合わせた。

重要なのは:

- 空 signature はダメ
- ABI decode 可能な well-formed signature にする必要がある

これにより、estimate 中の account validation で不要な revert を防げた。

---

## 6. verificationGasLimit に floor を持たせた

### 問題

estimate で返ってきた verificationGasLimit をそのまま final に使うと、本物の WebAuthn 検証コストに足りず

- AA26 over verificationGasLimit

を引いた。

### 対応

final 送信では verificationGasLimit に floor を持たせた。
今回のケースでは、最終的に 0xc3500 に戻して通した。

---

## 7. postOp を EntryPoint v0.7 に合わせた

### 問題

execution phase で postOp が revert していた。

最終的には、postOp のシグネチャが EntryPoint v0.7 に合っていなかったのが主因だった可能性が高い。

### 修正

EntryPoint v0.7 に合わせて、4引数版に修正した。

---

## 実際に遭遇した主なエラーと意味

`AA33 reverted`

### 原因:

- paymaster 署名対象が gas 系まで含んでいた
- bundler 側との差分で署名不一致になった

### 対応:

- final 署名対象から gas 系を外した
- gas は cap 管理にした

---

`AA21 didn't pay prefund`

### 原因:

- estimate で paymaster を完全に外したため、sender が prefund を払えなかった

### 対応:

- estimate でも paymaster を MODE_ESTIMATE で使うようにした

---

`AA23 reverted 0x`

### 原因:

- dummy signature が ABI decode 不能

- account validator が revert

### 対応:

- well-formed dummy signature を導入

- ABI 形を本物と統一

---

`AA24 signature error`

### 原因:

passkey signature の ABI 形が Solidity 側 decode と一致していなかった

### 対応:

- signature ABI を修正

- roundtrip decode を追加

---

`AA26 over verificationGasLimit`

### 原因:

- final の verificationGasLimit が足りなかった

### 対応:

- final で floor を設定

---

`AA50 postOp reverted`

### 原因:

- estimate/final の context / postOp 経路

- 最終的には postOp 実装側の問題

### 対応:

- estimate では context を空にした

- postOp を EntryPoint v0.7 に合わせた

---

## デバッグで有効だったもの

### 1. onchain debug 関数

paymaster 側 debug で確認したもの:

- mode
- reqHash
- signer
- recovered
- allowedCall
- enoughBalance
- gasCapsOk
  ※ ただし最終的に debug 側は一部 mode parse がズレていたため、補助用途に留まった。

---

### 2. final signature の roundtrip decode

これが非常に重要だった。

送信直前にフロント側で

- encode
- decode

を往復させて、Solidity decode 期待形と一致しているかを確認した。

確認項目:

- decodedCredHash
- decoded.authenticatorData
- decoded.clientDataJSON
- decoded.challengeIndex
- decoded.typeIndex
- decoded.r
- decoded.s

---

### 3. replay テスト

Foundry replay で切り分けできたもの:

- paymaster ではなく passkey validator が本丸だったこと
- laneValidator ではなく passkey signature 形が壊れていたこと
- memory allocation panic が ABI shape 問題だったこと

---

## 実装上の教訓

### 1. estimate と final は分ける

AA + paymaster + passkey の組み合わせでは、estimate と final を同一扱いすると壊れやすい。

### 2. paymaster 署名対象に gas を厳密に入れすぎない

bundler が関わる gas 系は、厳密 hash より cap 制御の方が安定する。

### 3. WebAuthn/passkey の署名は ABI 形が命

cryptographic failure より前に、ABI shape mismatch で壊れることがある。
まず decode が roundtrip で通るかを見るべき。

### 4. postOp は EntryPoint version と揃える

EntryPoint の version に対して、paymaster 側 postOp のシグネチャがズレると execution phase で落ちる。

---

## 現在の成功条件

以下の条件で送信が通った。

- estimate 用 paymasterData: MODE_ESTIMATE
- final 用 paymasterData: MODE_FINAL
- final の gas は cap 管理
- passkey signature ABI は Solidity decode と一致
- final 送信前の roundtrip decode が一致
- verificationGasLimit は floor を持たせる
- postOp は v0.7 に合った形

---

## 今後の改善候補

### 優先度高

- paymaster debug 関数の mode / parse のズレ修正
- 成功ケース fixture の固定保存
- 成功した final payload を replay テスト化

### 優先度中

- gas floor の最適化
- postOp の refund ロジック検証
- lane validator / passkey validator の debug helper 整備

### 優先度低

- paymaster debug 出力の整形
- Tenderly trace を前提にした revert selector 集の整理

---

## 保存しておくべき成果物

- 成功した ContextObservatoryPaymaster.sol
- 成功した sendUserOp.ts
- 成功した passkeyAssertion.ts
- 成功時の finalRpcUserOp
- 成功時の finalUserOpHash
- 成功時の replay fixture JSON
