# 變更紀錄

本專案所有值得記錄的變更都寫在這裡。
English version: [CHANGELOG.md](CHANGELOG.md)

版本規則：小版號逐次遞增，到 .99 才進位到次版號 —— 0.7.0、0.7.1、……、0.7.99，然後 0.8.0。所有 0.x 版本都屬於預先發行版；1.0.0 的門檻是實機測試通過。

## [0.7.9~beta1] - 2026-07-27

### 修正
- **`pve-dell-config-get --insecure` 完全沒有作用。** 它背後那個運算式的兩個分支產生的是同一個值，因此不論有沒有加這個旗標，憑證驗證都是關閉的。在 recover 模式下它維持預設關閉 —— 這與外掛本身 `dell-ssl-verify` 的預設一致，而且在故障復原途中跳出憑證錯誤是阻礙而不是保護 —— 並新增 `--verify-ssl` 來開啟。這兩個旗標現在在「從 `storage.cfg` 取得陣列資訊」時也同樣有效。
- **`pflex-protection-domain` 先前只是個平手時的裁決條件。** 只有在儲存池名稱有歧義時才會被參考，不歧義時就被忽略，於是設定了保護網域的儲存仍可能被指到另一個網域裡的儲存池 —— 而那正是指定網域想避免的事。現在它是必要條件；若該名稱的儲存池不在指定的網域中，會直接拒絕，並列出它實際所在的網域。
- 當某個端點管理超過一個 PowerFlex 系統時，會明講，而不是默默使用列在最前面的那一個。
- 建立時未指定 type 的 REST 客戶端，不會再在它要回報的錯誤上面，多疊一個未初始化值的警告。

### 新增
- `docs/TESTING.md` 說明每一個未驗證的端點該去哪裡確認：PowerStore 的陣列本身就提供 Swagger UI（`https://<mgmt-ip>/swaggerui`），而 PowerVault 的指令可以先用 SSH 試跑，再交給外掛以 HTTPS 送出。
- `t/16-docs.t` 會實際執行災難復原工具的 `--help`。Getopt::Long 是在被呼叫時才驗證它的選項表，而不是在檔案編譯時，而故障當下是最不適合發現選項表壞掉的時刻。

## [0.7.8~beta1] - 2026-07-27

### 修正
- **PowerFlex 的選項完全沒有文件。** 五個都沒有，包括必填、而且 PowerFlex 本身沒有預設值的 `pflex-storage-pool`。`docs/CONFIGURATION.md` 與其繁體中文版現在都描述了這些選項，並一併說明該系列 8 GiB 的配置單位、31 個字元的名稱上限，以及在 NVMe/TCP 與 SDC 之間選擇實際上代表什麼。

### 新增
- `t/15-pve-contract.t`：直接讀取已安裝的 `PVE::Storage::Plugin`，在下列情況失敗 —— 本外掛會繼承到「會去呼叫 `filesystem_path`」或「預設就 die」的基底方法、宣告的 API 版本落在執行中 PVE 可接受的範圍之外、或三個外掛中有兩個宣告了相同的屬性名稱（這會讓 PVE 在建立儲存 schema 時直接 die，並讓節點上所有儲存一起停擺）。日後 PVE 升級若動到這些，會在這裡就失敗，而不是在生產環境才發現。
- `t/16-docs.t`：當選項存在卻沒有文件、文件寫了不存在的選項（管理者照抄進 `storage.cfg` 會導致整個儲存被拒絕），或某份文件缺少另一種語言的對應版本時，測試失敗。
- `make release-check` 現在也會檢查兩份 README 與文件網站，包括版本標章，以及網站上是否已有這次發布的變更紀錄條目。

## [0.7.7~beta1] - 2026-07-27

### 修正
- **名稱比對改為精確錨定。** Perl 的 `$` 也會匹配「字串結尾的換行之前」，因此 `"vm-100-disk-0\n"` 會通過一個原本應該完全相符的樣式，並解析到與乾淨名稱相同的陣列物件。現在所有名稱樣式都以 `\z` 結尾。
- **長到不可能是 vmid 的數字串不再被解讀為 vmid。** Perl 在第一次以數值使用它時會轉成浮點數，因此一個由三十個 9 組成的名稱會解出 `1e+30` 這個 vmid —— 而它會就這樣被帶進 volid 裡。
- **列表中不是雜湊的資料列不再讓呼叫端整個掛掉。** 直接解參考會拋出 Perl 型別錯誤而不是略過該列，於是一個非預期的回應格式就足以讓整份列表失效。

### 新增
- `t/14-parsing.t`：把「缺少的、改名的、型別不對的」欄位丟給外掛裡的每一個解析器 —— WWN 轉換、PowerVault 的 CLI status 物件、容量欄位、volume 資料列、陣列物件名稱，以及 PVE 的 volume 名稱。這些客戶端裡的每個欄位名稱都來自文件而不是實際的陣列，因此其中一定有寫錯的；這份測試要求的是「猜錯時安全地失敗」，而不是照著錯的值繼續動作。

## [0.7.6~beta1] - 2026-07-27

### 修正
- **對裝置路徑做檔案測試也可能卡住。** `-b` 是一次 stat；當某個 multipath 裝置的所有路徑都失效、而 queueing 仍然開著時，這個 stat 會進入與「讓 `vgs` 卡死」相同的不可中斷睡眠。現在所有這類測試都改走 `Multipath::is_block_device`，由它加上時間上限 —— 並且會把呼叫端原本設好的 alarm 放回去，因為沒有這一步的巢狀 `alarm()` 會默默取消呼叫端自己的逾時保護，那比它想防的卡住更糟。
- **`volume_resize` 會先等陣列回報新的容量**，才去處理主機端。在 resize 還在進行時就發出逐裝置重新掃描，kernel 會停留在舊容量，QEMU 的 `block_resize` 便會對一顆其實已經長大的 volume 回報「Cannot grow device files」。這個等待有時間上限，而且無論如何都還是會做主機端的重新整理。

### 變更
- 套件移除腳本會列出哪些儲存將因此停止運作，直接讀取 `storage.cfg`。改用 `pvesm` 詢問就得去連上每一台陣列才能回答，而一個卡住的移除會讓 dpkg 停在半設定狀態。

## [0.7.5~beta1] - 2026-07-27

以「陣列實際會出現的狀態」而非「文件上描述的狀態」來測試。

### 修正
- **並行配置可能直接失敗，而不是改用下一個編號重試。** 選定 disk id 與建立 volume 是兩個步驟，而 PVE 的配置是平行執行的；但「這個編號是不是已經被拿走」的檢查卻放在重試迴圈外面。於是在競爭中落敗的那個工作行程，會因為一個它其實還可以自由更換的名稱而直接失敗。這是由「16 個行程同時對同一個共用陣列配置」的測試找出來的。

### 新增
- `t/12-adverse.t`：一台故意行為不良的真實 HTTP 伺服器 —— 接受連線後完全不回應、回應到一半就斷、以 200 回一段 HTML、直接關閉連線不回應、拒絕帳密、登入成功卻不給 token。每一種情況都必須快速失敗、訊息中要指出是哪個儲存，而且絕不能卡住。它同時證明「以 5xx 失敗的建立請求只會送出一次」：該請求可能其實已經送達陣列，重試會讓一顆 PVE 磁碟變成陣列上的兩個 volume。
- `t/13-hostile.t`：損毀的狀態檔（空檔、截斷、二進位、結構不對的 JSON）、守護所有破壞性路徑的所有權判斷、含有路徑穿越與 shell 特殊字元及非 ASCII 文字的 storage id、各系列在對齊邊界上的容量計算、PowerVault 的增量式擴充，以及 16 路並行配置。
- `docs/TROUBLESHOOTING_zh-TW.md`：在陣列端手動移除 LUN 之後，殘留 sd 路徑該怎麼處理。沒有任何機制會自動移除 sd 裝置，而它們會一直安靜到下一次 `multipathd` reload 時，才用 EBUSY 灌滿 journal。

## [0.7.4~beta1] - 2026-07-27

延續對兩個相關專案事故紀錄的逐條檢查，並比對 Dell 官方的 PowerStore 與 PowerVault 手冊。

### 修正
- **儲存 API 版本改為協商，不再寫死。** 當外掛宣告的版本比執行中的 PVE 還新，PVE 會直接拒絕載入 —— 該類型的所有儲存都會從節點上消失；宣告得比較舊則會讓 PVE 在每次載入 `PVE::Storage` 時印出 `implementing an older storage API`，也就是每執行一次 `pvesm`、每啟動一次 daemon 都印一次。PVE 9 在 9.1 的小版本之間就把 `APIVER` 提高了兩次，所以任何固定數字必然在某些版本上是錯的。現在改為宣告「執行中的 PVE 所要求的版本」，上限是本外掛真正實作過的最新版本。
- **`volume_resize` 處理儲存 API 14 新增的 `$snapname` 參數。** 先前直接忽略它，因此「調整快照大小」的請求會變成調整該快照的來源 volume。現在會明確拒絕並說明原因。
- **刪除快照時，會先釋放正在讀取它的暫時複製。** 這正是 `vzdump` 快照模式的流程：PVE 建立快照、透過 `path()` 讀取它（這需要在陣列上做一份該快照的複製），備份一完成就立刻刪除快照。陣列不會允許刪除一個「已被複製」的快照，因此每一次這種備份都會在清理階段失敗，並在陣列上留下複製、在本節點留下裝置。Dell 的 PowerVault 手冊把規則寫得很清楚：帶有子快照的 volume 或快照，必須先刪掉子快照才能刪除。
- **殘留裝置清理不會去動任何「仍有可用路徑」的裝置。** 熱新增到執行中 VM 的磁碟，會有一小段時間不出現在陣列的列表中，而客體其實已經打開了它；而客體開啟的檔案描述子既不是 holder 也不是掛載點，因此「是否使用中」的檢查看不到它。在執行中的客體底下把 map 拔掉，對它而言就是一顆全新磁碟立刻出現 I/O 錯誤。
- **中斷改以時間長度判定，而不是輪詢次數。** PVE 一旦把儲存標成 inactive 就會有一段時間不再詢問，因此一次真實的中斷可能只會進到外掛一兩次 —— 需要連續三次失敗的計數器，正好會在最該回報的中斷中保持沉默。`activate_storage` 也會記錄自己失敗的原因：PVE 先呼叫它、失敗就不會走到 `status()`，而陣列不可達時失敗的正是它。
- **`volume_snapshot_info` 與 `rename_snapshot` 改為自行實作。** 基底類別的版本是透過 `filesystem_path` 去讀 qcow2 檔案，而本外掛無法提供該方法，於是會以一個跟呼叫者無關的錯誤訊息失敗。
- **PowerVault 在還原時會回答確認提示。** CLI Reference 記載的語法是 `rollback volume [prompt yes|no] snapshot <snap> <vol>`；不帶這個參數，陣列就會一直等一個腳本永遠不會給的答案。
- **PowerFlex 回報真正的快照時間**，不再把每個快照都顯示成 1970 年。
- **`pve-dell-config-get` 的 `mount` 與 `umount` 加上時間上限。** 它是在故障期間、對著可能只剩半條命的儲存執行的，沒有上限的 mount 會永遠不回來。

### 變更
- **拒絕還原到「不是最新」的快照。** Dell 手冊說明了「從快照還原 volume」對該 volume 的影響，卻沒有說明那些在還原點之後才建立的快照會怎麼樣。若陣列會把它們清掉，PVE 仍會繼續列出已經不存在的還原點。現在會把擋住它的快照清單交給 PVE 顯示，做法與內建那些「還原具破壞性」的外掛一致。

### 新增
- `dell-rollback-any-snapshot`（布林，預設關閉）：讓已在自己陣列上驗證過行為的管理者解除上述限制。

## [0.7.3~beta1] - 2026-07-27

對照兩個相關專案 [jt-pve-storage-netapp](https://github.com/jasoncheng7115/jt-pve-storage-netapp) 與 [jt-pve-storage-purestorage](https://github.com/jasoncheng7115/jt-pve-storage-purestorage) 的實際生產事故紀錄逐條檢查。每一類已記錄的故障都在本專案的程式碼中追過一遍，其中九項確實也存在。

### 修正
- **被陣列拒絕的刪除可能被回報成成功。** `free_image` 在中間夾了其他 `eval` 之後才讀 `$@`，而 `eval` 會把它重設。於是陣列拒絕刪除時的回傳值與成功時完全相同，PVE 便把磁碟從 VM 設定中移除，而 volume 其實還在陣列上。現在會在刪除回傳的當下立刻把錯誤接住。
- **volume 可能在仍被對應的狀態下被刪除。** 當陣列沒能回答某個 volume 對應到哪些 host 時，`free_image` 仍會繼續往下刪。每一台仍對應著它的節點都會留下一個不會回應的裝置，任何碰到它的行程都會卡在不可中斷睡眠。現在這個查詢失敗即視為致命錯誤 —— 這是可以重試的，殘留裝置不是。
- **殘留裝置清理曾經對每個 volume 各發一次陣列查詢。** 它跑在每次 `status()` 輪詢的背景中，因此負載會以（volume 數 × 節點數 ÷ 10 秒）成長 —— 這正是壓垮陣列管理介面的形狀。現在只使用列表查詢已經回傳的欄位；而當整份列表都沒有 WWID 時，會直接放棄該次清理，而不是推論成「所有 volume 都被刪掉了」。
- **讀取快照用的暫時複製可能洩漏。** 建立它的行程若在刪除前被砍掉，就會留下一個沒有 PVE volume 名稱的物件：它不會出現在任何列表中，而清理程序又不會去動陣列上仍然存在的物件。現在會以節點為單位記錄，並在建立它的行程消失後移除。
- **PowerStore 的列表查詢可能悄悄被截斷。** 分頁在收到比要求還短的一頁時就停止，但陣列本來就可以把單頁上限壓在要求值以下。被截掉的 volume 會從磁碟清單中消失，清理程序也會把它們當成已刪除。現在改為依照陣列回傳的 `Content-Range` 判斷。
- **PowerVault 與 PowerFlex 在建立物件後會等待它變成可見**，與 PowerStore 一致。建立成功並不保證下一個查詢就看得到它，而每一個呼叫端都會緊接著對它做對應或查詢。
- **PowerFlex 的所有回滾路徑都改為先解除對應再刪除**，而本節點無法對應的複製會被回滾，而不是留下一顆裝置永遠不會出現的磁碟。
- **接在裝置 glob 之後的區塊裝置檢查，改到與 glob 同一個逾時保護之內**。
- `PowerStore/API.pm` 呼叫了 `decode_json` 卻沒有 `use JSON`。

### 新增
- `t/11-imports.t`：`perl -c` 對「呼叫未定義的副程式」完全不會有意見，因此少寫一行 `use` 只會在執行期才爆 —— 而且是在面向陣列的路徑上爆，那正是沒有硬體就測不到的地方。上面那個漏掉的 `JSON` 就是這樣被找出來的。

## [0.7.2~beta1] - 2026-07-26

對照 Proxmox VE 9.2.5 的儲存 API 原始碼，逐一檢查外掛的每個進入點，以及各系列的 API 客戶端。共修正九項缺陷，每一項都會在實機測試的頭幾個小時內出現。

### 修正
- **PowerFlex 套用了錯誤的名稱長度上限。** `PowerFlex::Naming` 已把上限覆寫為 31 個字元，但繼承自 PowerVault 的方法直接讀取該系列的常數 32，因此每個產生出來的名稱都被允許超出一個位元組。storage id 稍長時，快照或連結複製就會被陣列拒絕。共用方法現在改為向類別詢問上限。
- **刪除 volume 時沒有一併清掉它的快照。** PVE 刪除 VM 磁碟時不會處理儲存端的快照 —— `qm destroy` 直接呼叫 `vdisk_free` —— 而範本一定帶著它的標記快照，因此兩者都會在陣列端失敗。現在會比照 Ceph 與 ZFS 外掛的作法，先刪掉本外掛自己建立的快照。範本標記留到最後處理，而且只有在陣列的拒絕理由與相依物件無關時才刪，因此仍有連結複製依賴它的範本會保留這個識別用的標記。
- **用來讀取快照的暫時複製，忽略了各系列的名稱長度限制。** 它是用字串直接串接出來的，長度會到 39 個位元組，PowerVault（32）與 PowerFlex（31）都會拒絕，因此這兩個系列根本無法讀取快照。現在改為統一走命名類別產生。
- **自動產生的 NVMe host NQN 沒有被保存下來。** `nvme gen-hostnqn` 每次呼叫都會產生一組新的隨機 NQN，於是陣列被告知的是 A、而 `nvme connect` 呈現的是 B，namespace 永遠不會出現。現在會以不覆寫既有檔案的原子方式寫入 `/etc/nvme/hostnqn`。
- **連結複製被列在錯誤的 volid 底下。** `clone_image` 回傳的是 `base-100-disk-0/vm-101-disk-0`，PVE 也是這樣存的，但 `list_images` 卻回報 `vm-101-disk-0`。這會讓 `qm rescan` 認為有一個沒有任何設定檔引用的 volume，於是再次把它加成未使用磁碟。現在改由陣列自身的中繼資料推導出母體；無法判斷的系列則以純名稱回報，與 LVM-thin 外掛的作法一致。
- **`vollist` 過濾採用前綴比對**，因此查詢 `vm-1-disk-1` 也會一併傳回 `vm-1-disk-10`。現在比照內建外掛改為完全相符。
- **PowerStore 可能在陣列已接受的操作上失敗。** 部分請求回應的是 202 與一個 job id，而不是完成後的物件，而程式緊接著就依名稱去查詢。建立與複製現在會等待物件出現。
- **PowerVault 會把 volume 回報為 0 位元組**，當 `show volumes` 只提供格式化字串而沒有 `-numeric` 欄位時。0 還會讓每次調整大小都看起來像是擴充。現在會退而解析格式化字串。
- **時鐘往回跳之後，週期性 SAN 重新掃描就停住了**，與先前在健康檢查冷卻時間修掉的是同一類缺陷。

### 變更
- host 註冊改為每個儲存最多每五分鐘檢查一次，而不是每次 `activate_storage` 都檢查 —— PVE 每次 pvestatd 輪詢都會呼叫它，而在 PowerVault 上這個檢查是一次完整的 `show host-groups`。
- `pve-dell-config-get` 遇到非 `dellpowerstore` 的儲存會直接拒絕，而不是拿 PowerStore REST 去跟其他系列的陣列講話，並會說明為什麼 PowerVault 上沒有設定備份。

## [0.7.1~beta1] - 2026-07-26

### 變更
- `dellpowervault` 系列不再提供 VM 設定備份卷。每次對 VM 做快照都會為了保存一份設定而多用掉一個 volume，而 PowerVault ME 陣列的 volume 與快照上限比 PowerStore 少了大約一個數量級 —— 少到這個代價足以決定陣列的 volume 會不會用完。快照、還原與連結複製都不受影響，設定也仍然可以從 PVE 備份、或從叢集中其他節點的 `/etc/pve` 取回。
- `Common::BlockBase` 新增 `supports_config_backup()`，由它在系列層級決定是否提供此功能，並用它把所有設定卷相關路徑都擋起來。

### 新增
- `dell-config-backup`（布林，預設開啟）：在有提供此功能的系列上把它關掉，適合 volume 數量已接近上限的 PowerStore。在不提供此功能的系列上設定它不會有任何作用。

### 修正
- 刪除快照或磁碟時，仍會清掉舊版本寫下的設定卷，即使此功能已經關閉 —— 否則那些 volume 會被遺留在陣列上。

## [0.7.0~beta1] - 2026-07-26

新增 PowerFlex 3.x 與 4.x 的 `dellpowerflex` storage type。

### 新增
- `PowerFlex/API.pm`、`PowerFlex/Naming.pm`、`PowerFlex/Host.pm` 與 `DellPowerFlexPlugin.pm`。
- `Common/Schema.pm`：把共用的 `dell-*` 選項抽出來，讓非 block 系列也能使用而不必繼承 `BlockBase`。
- `docs/POWERFLEX_SDC_zh-TW.md`：SDC 與 NVMe/TCP 的比較、Dell 支援矩陣的所在位置，以及如何確認某個 kernel 是否受支援 —— 以連結官方來源的方式呈現，而不是複製一份會過時的內容。
- README 加上三個系列各自的設定步驟，並在標題下方加上文件網站連結。
- 單元測試總計 991 個。

### PowerFlex 的特殊之處
- **它不繼承 block 基底類別。** volume 是透過 Dell 的 SDC kernel module 或 kernel 內建的 NVMe/TCP initiator 出現的；沒有 SCSI LUN、也沒有 dm-multipath，因此 `BlockBase` 對裝置所做的一切在這裡都是錯的。
- **預設是 NVMe/TCP。** Dell 針對 Proxmox VE 的說明列出 PVE 8.x 有 SDC 支援，PVE 9.x 則僅為*規劃中*；而且 `scini` 必須針對每個 kernel 編譯 —— 一次 kernel 升級就可能讓節點在模組重建之前沒有儲存。NVMe/TCP 用的是 Proxmox 已經提供的 kernel。
- **NVMe 的路徑走 ANA，逾時值很關鍵。** 連線時帶入 `ctrl-loss-tmo` 60 秒而非 kernel 預設的 600 秒：它是 NVMe 版的 `no_path_retry`，設成無上限會讓全路徑中斷看起來像當機。啟用時若偵測到 `nvme_core.multipath` 被停用、或只連上部分 target，都會提出警告。
- **兩種認證世代是自動偵測而非設定**：4.x 從 `/rest/auth/login` 取得 bearer token（五分鐘到期），3.x 從 `/api/login` 取得 token 再當成密碼使用。密碼被拒絕時絕不改用另一個端點重試，否則會讓帳號鎖定政策的失敗次數加倍。
- 容量向上對齊 8 GB 配置單位；名稱上限 31 個字元。

### 移除
- 內部開發規格書已不再放在 repository 中。

## [0.6.0~beta1] - 2026-07-26

新增 PowerVault ME4／ME5 系列的 `dellpowervault` storage type。

仍是 beta，也仍未經實機驗證。這次不同的是：面向陣列的細節是實際讀取《Dell PowerVault ME5 Series CLI Reference Guide》而來，不是憑記憶撰寫；[docs/TESTING_zh-TW.md](docs/TESTING_zh-TW.md) 也把「來自官方文件」與「尚未查證」分開列出。

### 新增
- `PowerVault/API.pm`、`PowerVault/Naming.pm` 與 `DellPowerVaultPlugin.pm`。
- 新增 154 個單元測試，總計 867 個。

### 這個系列的不同之處，以及為什麼重要
- **HTTP 200 不代表成功。** ME 是把 CLI 透過 HTTPS 開放出來；被拒絕的指令一樣回 200，判斷結果放在 `status` 物件裡。若以 HTTP 狀態碼為準，建立失敗的 volume 看起來會像成功，PVE 就會記錄一顆並不存在的磁碟。
- **`expand volume` 收的是增量，不是總量。** PVE 給的是新的絕對容量。直接傳過去，會把使用者要求擴充到 33 GiB 的 32 GiB volume 變成 64 GiB。
- **容量在這裡要向上取整。** 陣列以 4 MiB 對齊且**向下**取整，所以客戶端必須先向上取整，否則實際 volume 會小於 PVE 以為的大小。
- **名稱上限 32 bytes 且不可含句點。** 因此這個系列有自己的命名模組：較短的物件名稱、以 `-s-` 而非句點作為快照分隔符號，以及 storeid 的 10 字元額度。放不下的名稱會直接報錯，而不是被截斷成可能與其他 VM 撞名的名稱。
- **連結複製就是快照。** ME 的快照可寫入也可對應，所以複製即是「取一個 volume 形狀名稱的快照」—— 瞬間完成，且不複製資料。

### 變更
- 路線圖：PowerStore → PowerVault ME → PowerFlex → PowerMax；PowerScale 未排入。
- type 字串為 `dellpowervault` 而非 `dellme5`：其他系列都以產品線而非型號命名，而且 ME4 與 ME5 共用同一套 API。

## [0.5.0~beta1] - 2026-07-26

Phase 2 至 4。`dellpowerstore` storage type 已經存在。

> 它**尚未**在任何 PowerStore 陣列上執行過。所有面向陣列的細節在 [docs/TESTING_zh-TW.md](docs/TESTING_zh-TW.md) 中仍標記為未驗證。1.0.0 的門檻是實機測試通過，而不是再寫更多程式。

### 新增
- `Common/BlockBase.pm`：抽象的 PVE plugin 基底。SAN 啟用、配置、裝置探索與拆除、快照、範本、複製、multipath drop-in，以及背景 orphan 清理 —— 全部與「背後是哪一台陣列」無關。系列 plugin 只需實作 `_array_*` 方法，其餘全部繼承。
- `PowerStore/API.pm`：涵蓋 volume、快照、精簡複製、host、對應關係與傳輸端點的 REST 客戶端，附 fixture 與 96 項請求格式測試。
- `PowerStore/Naming.pm`：PowerStore 較寬鬆的名稱限制。
- `DellPowerStorePlugin.pm`：storage type 本身，以及 PVE 要註冊的 schema。
- `bin/pve-dell-config-get`：把每次快照旁邊那個設定備份卷裡的 VM 設定讀回來。復原模式下它會自己解析 `storage.cfg`，或直接由命令列取得陣列資訊，完全不經過 pvesm —— 因為這個工具存在的情境，正是 `/etc/pve` 已經不在、或 pvedaemon 起不來的時候。
- 文件：快速上手、設定參數說明、架構說明、疑難排解、命名慣例與實機測試矩陣，皆有英文與繁體中文版本，另有 `docs/` 底下的專案頁面。

### 值得知道的行為
- Volume 在建立時就會對應到所有節點，讓線上遷移不必先重新對應；而解除對應一律在刪除之前 —— 相反的順序會讓任何節點上正在進行的重新掃描把該 LUN 重新匯入，在刪除的背後又把裝置建回來。
- LUN ID 由外掛自行配發，從 `pstore-lun-id-base` 往上補空號。PowerStore 自己的 REST 端序列從 200 開始且不重用 ID，因此不斷掛載卸載的叢集，最終會把它推到超過主機掃描範圍，新磁碟就再也不會出現。
- Volume 容量會向上對齊 PowerStore 要求的 8 KiB 粒度。向下取整會交回一個比 PVE 要求還小的 volume。
- `make syntax` 對需要 Proxmox VE 的模組會回報為「已跳過」而不是失敗，讓一般 CI runner 上的結果是誠實的，而不是碰巧變綠。

## [0.2.0] - 2026-07-26

Phase 1 — 共用的 Common 層。尚未註冊任何 storage type，這些是各系列 plugin 之後要建立在其上的模組。

### 新增
- `Common/Naming.pm`：物件命名、PVE volume 名稱轉換，以及 `is_pve_managed_volume` 這道 `pve-<storeid>-` 歸屬檢查 —— 所有列舉、刪除與清理路徑都必須先通過它。全部採用 class method，讓各系列以繼承方式放寬名稱長度限制，不需引入共用的可變狀態；因為單一 PVE 行程會同時載入所有 Dell plugin。
- `Common/REST.pm`：HTTP 傳輸層。POST 遇到 5xx 一律不重試，因為請求可能已經在陣列上生效，重試會多建立一個 volume。401 會清掉 session 並重新登入重試一次。429／503 採退避策略，遵守 `Retry-After` 但上限 30 秒。session 記錄建立它的行程編號，讓 fork 出來的 PVE worker 重新認證，而不是沿用不屬於自己的 session。以 `retries => 1` 搭配短逾時建構，即為 `activate_storage` 與 `status()` 所需的健康檢查用戶端。
- `Common/Multipath.pm`：裝置生命週期處理，自 NetApp 與 Pure plugin 移植並將 vendor 判斷參數化。程式中絕不會產生 `multipath -F`：`multipath_flush` 一定要有裝置參數。所有 sysfs 存取都在有逾時限制的子行程中進行，因為直接讀取已失效的 LUN 會陷入任何訊號都無法中斷的睡眠狀態。
- `Common/ISCSI.pm`：initiator 身分、portal 預檢、session 生命週期，以及會跳過非 `LOGGED_IN` session 的逐一 rescan。
- `Common/FC.pm`：HBA 探索與 WWN 正規化（同一個 WWN 會以三種寫法出現）。預設不發出 LIP。
- `Common/WwidState.pm`：節點端的 WWID 追蹤，包含 orphan 清理前必須同時通過的寬限期與連續未命中門檻，以及同節點其他 Dell 儲存的辨識，避免把別的儲存正在使用的裝置誤報為殘留。
- `Common/Health.pm`：`status()` 用的中斷偵測與容量告警，並加上頻率限制，避免約 10 秒一次的輪詢灌爆 journal。
- 342 個單元測試（`t/01-naming.t` 至 `t/05-state.t`），在不需要陣列與實體裝置的前提下涵蓋重試策略、清理防護、歸屬檢查與 taint 處理。

### 修正
- 有頻率限制的健康訊息改為明確判斷「從未發送過」，並把未來的時間戳記視為應該發送。先前兩者都依賴與 0 相比的 epoch 運算，因此時鐘往回校正一次，就可能在時差消失前一直把真正的中斷事件靜音。

## [0.1.0] - 2026-07-26

Phase 0 — 專案骨架。本版本尚未註冊任何 storage type。

### 新增
- MIT 授權、雙語 README 骨架（含 multipath 安全規則與實機驗證免責聲明）。
- `Makefile`，提供 `install`、`uninstall`、`test`、`syntax`、`unit`、`check-multipath-flush`、`deb`、`clean` 等目標。模組清單改由 `lib/**/*.pm` 自動探索，不需手動維護，後續各階段新增模組時打包設定不必跟著改。
- Debian 打包檔：`control`、`rules`、`compat`、`changelog`、`copyright`、`docs`、`postinst`、`prerm`、`postrm`。安裝動作透過 `override_dh_auto_install` 交由 Makefile 執行。
- `postinst` 檢查項目：必要執行檔是否存在（可攔截以 `dpkg -i` 安裝而未解相依的情況）、`/etc/multipath.conf` 與 `/etc/multipath/conf.d/*.conf` 中的危險設定、所有路徑皆失效的 Dell 殘留 map、缺少 LVM `global_filter`、進行中的儲存操作，以及叢集全節點安裝提醒。
- GitHub Actions 工作流程：安全檢查、`perl -c` 與單元測試通過後才建置 `.deb`。
- CI 檢查 `make check-multipath-flush`：只要程式碼或文件出現全系統 flush 的大寫 F 指令，建置即失敗；明確禁止該指令的敘述文字則放行。
- 多系列架構的目錄骨架（`lib/PVE/Storage/Custom/`、`DellEMC/Common/`、各系列子目錄、`t/`、`docs/`、`bin/`）。
