# Relationship

- author(shota moue)
- contextObserver(contract)
  - NBNP coin(Commemorative Coin)
- participants
  - who provide contexts
  - who quote contexts

# Process

1. stake(初めはなし。2epochからあり)

- 現状、1ETH預け入れで1post追加される想定(L2ならそこまで重要じゃない)
- TODO: 粗利として時間差でpost数が増えるようにする(上のstakeはただの対策でしかない)

2. createContext

- イメージは参考文書を出すイメージ

3. post, declare(commitのこと),

- NOTE: createContextでuriが引数になっているが、これcontextIdだけでいい気がする(もし、自分の方でNFTの中身を保存する場所代を提供するのであればいいが、ipfs以外の既存文書をそのままだすケースでは対象外になってしまう)
  - 結論: そのままURI形式にする
- 現状、context:commit=1:多
- NOTE: memoHash（おそらく、他のcontextを読んだユーザーの感想？みたいな位置付けになる文のハッシュ）を見えるようにするかどうか

4. finalize, setEnableRedeem(author側処理)

- NOTE: もしかすると、ここで一部epochの違いでredeemがうまくいかない人が出てくる可能性あり（もし、ユーザーごとのredeem権限にepochIDの紐付けをpostまたはcreateContext時にしていたら）(merkleRootで線型化する範囲は各々のユーザーのcommit?なら問題なし、全てなら問題が起きる可能性高い)

4. redeem(status: claimed)

# AA cover area

1. createContext
2. post(declare)
3. redeem

---

2/14
foundryに統一するか、デプロイや細かな操作をtsで行えることを踏まえて少しhardhatを残していくかを迷ってる。
