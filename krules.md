目標：
我們的目標是完成一個可以在全新的 ubuntu Server 上自動安裝openclaw的sh檔。
我們將直接用root身份來進行操作，以利~/ai-agent.sh檔的完成。


架構及說明：
- 在 Ubuntu 24.04 Server 上自動安裝 Docker 並建置三個完全隔離的openclaw實例。
- 每個實例將使用不同的容器名稱及端口，以確保隔離：
    - ~/openclaw-1   :18789
    - ~/openclaw-2   :18889
    - ~/openclaw-3   :18989
- 每個實例將使用不同的數據存儲路徑，以確保隔離。
- 每個實例將使用不同的 token，以確保隔離。
- 每個實例將使用不同的環境變數，以確保隔離。


你必須不斷地嘗試直到上述任務完成為止。你必須常常更新ai-agent.sh檔。sh檔必須保持最新狀態。


每次有關於openclaw的操作，請先參考：
https://github.com/openclaw/openclaw
以及
https://docs.openclaw.ai/

若收到指示“參考官方”時，請依照這兩個網站。


- 討論模式：「討論討論」= 僅規劃不執行；「goo」= 開始執行。
- Git 指令 (giiit)：
    - 收到 giiit 指令才進行 commit & push。
    - Commit 格式：標題 < 50 字元。內容每一行 < 70 字元，每一行前面加 '- '，每一行都要斷行。
    - 流程：一般的 git add / git commit / git push 或讀取行為請直接執行 (Always Proceed)；Force push 或類似刪除行為才會詢問。


