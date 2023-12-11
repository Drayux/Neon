# import asyncio
# from websockets.sync.client import connect

# with connect("ws://irc-ws.chat.twitch.tv:80") as ws:
#     ws.send("PASS oauth:h4h43lzrzeoqjckdsk1kc9ejm3z79v")
#     ws.send("NICK xenoderg")
#     ws.send("JOIN #drayux")
#     while True:
#         message = ws.recv()
#         print("Message: ", message)

import asyncio
import websockets

async def hello():
    uri = "ws://irc-ws.chat.twitch.tv:80"
    async with websockets.connect(uri) as websocket:
        await websocket.send("PASS oauth:oopsies!")
        await websocket.send("NICK mysterious bot name")
        await websocket.send("JOIN #even more mysterious channel!")
        while True:
            message = await websocket.recv()
            print("message: ", message)

if __name__ == "__main__":
    asyncio.run(hello())
