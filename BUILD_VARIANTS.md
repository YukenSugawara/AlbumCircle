# 個人利用版とApp Store版

同じブランチ・同じソースから、Xcodeのスキームで切り替えます。

| スキーム | Bundle ID | プラン |
| --- | --- | --- |
| AlbumCircle-AppStore | com.example.AlbumCircle.AppStore | 無料／月額／年額 |
| AlbumCircle-Personal | com.example.AlbumCircle | 広告なし・プレミアム常時有効 |

従来の `AlbumCircle` スキームもApp Store版です。個人版はRunにPersonalDebug、ArchiveにPersonalReleaseを使います。個人版は `PERSONAL_EDITION` によって広告の初期化・リクエストとStoreKit購入処理を実行しません。広告SDKのパッケージ依存関係は共通ターゲットに含まれます。

端末内データはBundle IDごとに分かれます。iCloudコンテナは両方とも既存の `iCloud.com.example.AlbumCircle` を利用します。同じiCloudアカウントで作成したクラウドアルバムは共有されます。各App IDにこのコンテナを関連付けて署名してください。

## 写真枚数のルール

無料版の上限は、仮設定として1アルバム100枚です。`PhotoQuota.freePhotosPerAlbum` で変更できます。フォルダ内も含むアルバム全体を数え、同じ原本の重複は追加枚数に含めません。端末内・iCloud・参加中の共有アルバムに適用し、追加操作をする本人のプランで判定します。既存写真の閲覧・書き出し・削除は制限しません。

取り込み時と再開時に購入状態を確認し、無料版では保存前に最新の枚数を読み直して逐次保存します。上限に達した場合は残りの取り込みを停止し、元写真は削除しません。個人版・有料版は枚数上限を適用しません。枚数のチェックはアプリ側で行うため、複数端末・複数メンバーが同時に追加する場合の厳密な共有枠の保証はありません。共有枠をサーバーで厳密に制御する仕組みは別途必要です。

## 公開前に設定する項目

XcodeのAlbumCircleターゲットのBuild Settingsにある次のUser-Defined設定を入力します。価格はアプリに固定せず、App Storeから取得した表示価格を使用します。

| 設定 | 内容 |
| --- | --- |
| ADMOB_APP_ID | AdMobのiOSアプリID。Releaseに本番IDを設定 |
| ADMOB_BANNER_ID | AdMobのバナー広告ユニットID |
| PREMIUM_MONTHLY_PRODUCT_ID | App Store Connectで登録した月額商品のID |
| PREMIUM_YEARLY_PRODUCT_ID | 同じサブスクリプショングループの年額商品のID |
| PRIVACY_POLICY_URL | 公開済みのプライバシーポリシーURL |

DebugはGoogleのサンプルアプリIDとテスト広告ユニットを使います。Releaseは広告IDが未設定の場合、広告をリクエストしません。商品未登録・未設定時は購入可能なプランが表示されません。プライバシーポリシーURLが未設定の場合も購入ボタンは有効になりません。

AdMobのPrivacy & messagingで必要な同意メッセージを設定してください。UMPで同意状態を確認してから広告を開始し、必要な場合は設定画面からプライバシー設定を再表示できます。広告は非パーソナライズを要求し、アプリからATTの許可を要求しません。公開前に実際のSDKによるデータ収集内容に合わせてプライバシーポリシーとApp Store Connectのプライバシー情報を整備してください。

## 検証

- 両スキームのDebugとReleaseをビルドする。
- 個人版は初回起動からプレミアムが有効で、購入や広告通信を開始しないこと。
- App Store版はStoreKit ConfigurationまたはSandboxで月額／年額購入、承認待ち、キャンセル、復元、契約失効・返金を確認する。
- UMP同意が必要な地域／不要な地域とオフライン状態を確認する。
- 実際の購入・本番広告配信にはApp Store Connect／AdMob側の登録が必要。

参照: [StoreKit](https://developer.apple.com/documentation/storekit/transaction/currententitlements)、[AdMob導入](https://developers.google.com/admob/ios/quick-start)、[UMP](https://developers.google.com/admob/ios/privacy)。

## 写真の位置情報

写真アプリの撮影場所、またはファイル内のGPS情報を端末内・iCloudの両方に保存します。画質変換時はJPEGにもGPS情報を引き継ぎ、写真アプリへの復元時にも撮影場所を設定します。既存写真は原本にGPS情報が残っていれば詳細画面から確認できます。すでに失われた位置情報は復元しません。

CloudKitの `Picture` レコードに `location`（Location型）を追加しています。TestFlight・App Store版を配布する前に、開発環境で位置情報付き写真を追加してスキーマを確認し、CloudKit Consoleで本番環境に反映してください。共有アルバムでは撮影場所も共有メンバーが確認できます。端末の現在地は取得しません。

画質変換後もファイル名は拡張子を含めて保持します。画像データ自体はJPEGのため、詳細画面の形式表示と写真アプリへの保存では拡張子ではなく実データの形式を使用します。

## iCloud Driveバックアップ

設定の「写真のバックアップ」で、自動実行の有無、毎日／毎週、時刻、毎週の曜日を指定できます。初期設定はオフ、毎日02:00です。端末の現在のタイムゾーンを使用します。iOSのBGProcessingTaskで指定時刻以降の実行を予約し、実行されなかった分はフォアグラウンドで補完します。失敗時は1時間後以降に再試行します。指定時刻ちょうどの実行は保証されません。

両App IDでiCloud Documents（CloudDocuments）を有効にし、既存コンテナ `iCloud.com.example.AlbumCircle` を関連付けて署名プロファイルを更新してください。バックグラウンド実行IDは `$(PRODUCT_BUNDLE_IDENTIFIER).backup` です。CloudKitのスキーマ追加は不要です。

保存先はiCloud Driveの「アルバムの輪／Backups／版／端末ID／アカウント別キー」です。アプリ内の全アルバム（端末内・参加中の共有アルバムを含む）を対象とし、写真アプリ全体は対象外です。別端末と別版のバックアップが上書きし合わない構成です。

`Photos` 内にはファイル名を保持した原本を保存し、SHA-256でコピーを検証します。同じ内容・ファイル名の原本は既存コピーを検証して再利用します。原本の取得には通信が必要な場合があります。各回の `Backup-日時-UUID.json` にはアルバム・フォルダ構成、原本の相対パス、ハッシュ、撮影日、位置情報、回転、お気に入りを記録します。全件が完了するまで完成カタログは作成せず、過去のカタログや原本は削除しません。中断された回の保存済み原本は次回再利用できます。

「最終バックアップ作成」はiCloud Driveへの書き出し・ローカル検証の完了時刻です。iCloudサーバーへのアップロード完了とは区別します。端末の容量不足・通信・iCloud同期状態は実機でも検証してください。ファイルアプリから原本を選んで再取り込みできますが、JSONからのアルバム構成の一括復元は未実装です。
