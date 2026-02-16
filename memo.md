# Relationship

- author(shota moue)
- contextObserver(contract)
  - NBNP coin(Commemorative Coin)
- participants
  - who provide contexts
  - who quote contexts

# Process

1. stake(初めはなし。2epochからあり)

- 現状、1ETH預け入れで1post追加される想定(L2ならそこまで重要じゃない)(withdrawして再度stakeしても復活しない)

2. createContext

- イメージは参考文書を出すイメージ

3. post, declare(commitのこと),

- NOTE: createContextでuriが引数になっているが、これcontextIdだけでいい気がする(もし、自分の方でNFTの中身を保存する場所代を提供するのであればいいが、ipfs以外の既存文書をそのままだすケースでは対象外になってしまう)
  - 結論: そのままURI形式にする
- 現状、context:commit=1:多
- NOTE: memoHash（おそらく、他のcontextを読んだユーザーの感想？みたいな位置付けになる文のハッシュ）を見えるようにするかどうか
  - 結論: finalize(epochId=1)後にmemoContentは常に公開されるようにする

4. finalize, setEnableRedeem(author側処理)

- NOTE: もしかすると、ここで一部epochの違いでredeemがうまくいかない人が出てくる可能性あり（もし、ユーザーごとのredeem権限にepochIDの紐付けをpostまたはcreateContext時にしていたら）(merkleRootで線型化する範囲は各々のユーザーのcommit?なら問題なし、全てなら問題が起きる可能性高い)
  - 結論: author依存のため心配なし

5. redeem(status: claimed)

# AA cover area

1. createContext
2. commitDeclaration
3. redeem

# Observation Perspective

- 既存設計だと以下のようになるイメージ
  - 初期は同一ユーザーがcontext作成/commit(decraration)でspanStart~Endは作成したもの全てになるかなと思ってる
  - finalize後に、context作成者とcommit(decraration)が徐々に異なるユーザーになっていく(引用の粒度もどんどん細かくなる)

---

# AA関連コントラクト内訳

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

---

2/14
foundryに統一するか、デプロイや細かな操作をtsで行えることを踏まえて少しhardhatを残していくかを迷ってる。
