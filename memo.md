# Relationship

- author(shota moue)
- contextObserver(contract)
  - NBNP coin(Commemorative Coin)
- participants
  - who provide contexts
  - who quote contexts

# Process

1. stake(初めはなし。2epochからあり)

- 現状、**0.01 ETH** の stake により、`commitDeclaration` の許容量が **+1** 増える想定（`_allowedPosts = basePostLimit + effectiveStake/0.01 ether`）。
- `effectiveStake` は **matured + (pendingがmatured時刻を超えていればpending)** で計算される。
- 結論：stakeしてからcommitできるまでにタイムラグをおく(10min)。
  - NOTE: `pending -> matured` への遷移は `_syncStake` を呼ぶタイミング（例：`commitDeclaration` / `withdrawStake` / `depositStake`）で行う。
  - NOTE: 既に pending がある状態で追加 deposit しても、**既存pendingの成熟時刻は延長しない**（= stakeするたびに全て10min待たせない）。
- `createContext` は stake gating の対象ではなく、epochごとの **rate limit**（`contextCreateLimitPerEpoch`）のみで制御する。

2. createContext

- イメージは参考文書を出すイメージ(ブランド的にはユーザー自身の背景を共有してほしい。)
- 大量スパム防止のため、以下の関数をownerのみ設定できるようにした。(UI上でも表示されないようにhiddenする作業も行う。)
  - `setContextCreateLimitPerEpoch`: epochごとのレートを設定。(0なら無制限)
  - `setContextCreateUsage`: 実質的にepochごとにユーザーを凍結するため関数。(例：limit3なら第二引数に3を入れる)
- 初期は以下のフォーマットでUI上では提出してもらう。(JSON)
  - YOUR_LIEF
  - MEANING_LABEL
  - FOR_WHAT
  - (途中からはMARKDOWNで自由形式にする時のキー) FREE_CONTENT

## Invariants

**`contextCreateLimitPerEpoch=0`以外&`setContextCreateUsage未使用`**

- 各epoch内で、各ユーザー１回以上は呼べる

3. commitDeclaration

- NOTE: createContextでuriが引数になっているが、これcontextIdだけでいい気がする(もし、自分の方でNFTの中身を保存する場所代を提供するのであればいいが、ipfs以外の既存文書をそのままだすケースでは対象外になってしまう)
  - 結論: そのままURI形式にする
- 現状、context:commit=1:多
- NOTE: memoHash（おそらく、他のcontextを読んだユーザーの感想？みたいな位置付けになる文のハッシュ）を見えるようにするかどうか
  - 結論: finalize(epochId=1)後にmemoContentは常に公開されるようにする(UI上からであれば、FREE_CONTENTキーで表現)

## Invariants

**`useStakeGating=false`の時**

- 全てのユーザーが3回は最低呼べる。
- 全てのユーザーは4回目以上は呼べない。

**`useStakeGating=true`の時**

- 呼ぶのが4回目以上の時、初回stake時から10min以降でないと呼べない。
- 呼ぶのが4回目以上の時、stake量が0.01eth未満の場合呼べない。

4. finalizeEpoch(author側処理)

- NOTE: もしかすると、ここで一部epochの違いでredeemがうまくいかない人が出てくる可能性あり（もし、ユーザーごとのredeem権限にepochIDの紐付けをpostまたはcreateContext時にしていたら）(merkleRootで線型化する範囲は各々のユーザーのcommit?なら問題なし、全てなら問題が起きる可能性高い)
  - 結論: author依存のため心配なし

5. redeem(status: claimed)

- 初期UI上ではownerが中身に対して返信をしてからREDEEMできるようにする
- UI上でownerからの返信を確認できるページも準備

## Invariants

**`finalizeEpoch未使用`**

- 全てのユーザーは呼べない

**`finalizeEpoch使用`&`epochs[epochId].redeemEnabled=true`あり**

- commitDeclarationsを過去実行していれば、どこかのepochIdではredeemできる

# AA cover area

1. createContext
2. commitDeclaration
3. redeem

# Observation Perspective

- 既存設計だと以下のようになるイメージ
  - 初期は同一ユーザーがcontext作成/commit(decraration)でspanStart~Endは作成したもの全てになるかなと思ってる
  - finalize後に、context作成者とcommit(decraration)が徐々に異なるユーザーになっていく(引用の粒度もどんどん細かくなる)

---

# AA関連コントラクト内訳(メモ)

- SmartAccount: ユーザーの「意図」の検証・権限有無などを統括するAAコントラクト
  - laneKey(処理文脈の識別子)
    - 1: ContextObservatoryV0.sol関連のdAppユーザー処理
      - executor: ContextObservatoryV0.solの代理処理用forwarder
      - validator: ??
  - Plugins(ERC6900系): executorの文脈処理依存の検証方法そのものを柔軟に拡張するもの
  - Modules(ERC7579系): プロトコルレベルの形式そのものを補償・担保するもの
- AccountFactory: 主に本アプリ経由で作成されたAAを管理する基準となるコントラクト
  - NOTE: 同じ文脈処理で重複したユーザーのAAは作成を許可しないようにするべきか？
    - そもそもAA作成のガス代がユーザー持ちだったらどちらでもいい
      - epochId=2以降では初回stake時に同時にAA作成ガス代も払ってもらうようにするか、初期からAA作成のガス代自体は全てこちら持ちにするか。
        - こちら持ちなら、文脈ごとにownerの被るAA作成はできないようにする
    - そもそも処理文脈を表現するlaneKeyがoperator依存だから、コントラクトに直接書く形にはできない(動的な状態変数とその操作関数が必要)

# AA関連コントラクト内訳(確定)

- SmartAccount: ユーザーの意図検証・laneごとの実行ルーティング・ユーザー依存状態の保持を担う
  - laneKey(処理文脈の識別子)
  - laneごとの validator / hook / executor の参照先
  - passkey credential を保持する
- PasskeyValidator:
  - stateless な認証 validator
  - sender の SmartAccount から passkey credential を読む
- ContextObservatoryLaneValidator:
  - laneKey / target / selector の整合性を担う shared policy validator
  - 認証そのものではなく、処理文脈制約を担う
- ContextObservatoryExecutor:
  - target / selector を強制する shared executor
- ValidatorAggregator / ExecutorAggregator:
  - 開発側が管理する shared module surface
  - laneごとの child modules を合成・運用する場所
- AccountFactory:
  - laneKey ごとの bootstrap module registry
  - SmartAccount 作成時に shared aggregator modules を自動で紐づける
  - 結果としてユーザー側の account 作成を簡易化する

# デプロイ手順

## 開発側

### デプロイ対象一覧

- aggregator modules系
- aggregatorに紐づく子modules系
- smart accountを作成・管理するaccount factory
- paymaster系

### デプロイ方法

- `DeployAAInfra.s.sol` を呼ぶ
- laneKey ごとの shared validator/executor aggregators を deploy
- AccountFactory に bootstrap lane 設定を登録する

これにより、ユーザーが後から SmartAccount を作成する際、laneKey ごとの shared aggregator modules が自動的に account に紐づく

## ユーザー側

### デプロイ対象一覧

- SmartAccount 自体
- passkey credential の設定

### デプロイ方法

- フロントから passkey 作成時に SmartAccount を作成
- AccountFactory 経由で laneKey ごとの shared modules を自動セット
- その後、ユーザー固有の passkey credential を SmartAccount に保存

---

2/14
foundryに統一するか、デプロイや細かな操作をtsで行えることを踏まえて少しhardhatを残していくかを迷ってる。
