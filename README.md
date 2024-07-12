### NEON: Twitch integrations server

# About
Connect your stream to Twitch's interactions (follow/sub alerts, chat messages/commands, and point redeems) locally! Neon uses the **OBS Scripting Engine** to substitute the services provided by third-party utilities such as StreamLabs or StreamElements.

This current state of this project is merely what I have built for my own stream: [**twitch.tv/drayux**](https://twitch.tv/drayux). However if its adoption gains any popularity, I will likely try to retrofit this to a much more general-format type of project for the typical user.

Avid users of Firebot may wonder what this project offers instead. Both Neon and Firebot are built with the same goal in mind: to handle all stream integrations client-side. The major difference between the two is that Neon can be thought of as a "lightweight" version that runs _within_ OBS for those like me who wish to have all the magic happen seamlessly in the background. I strongly recommend that those who like pretty GUIs use [Firebot](https://firebot.app/) instead!

\<**TODO:** Add pretty pictures\>

# Dependencies
- cqueues: Lua event handling and socket management [Artix/Arch package: `lua-cqueues`]  
> [CQueues Homepage](https://25thandclement.com/~william/projects/cqueues.html)

- openssl: Library for TLS (Transport Layer Security, aka HTTPS/WSS) [Artix/Arch package: `lua-luaossl`]  
> Twitch requires TLS for the use of its API

- **Unix-based operating system** (aka this does _not_ work on Windows)  
> This isn't an effort to spite Windows users, merely an unfortuante side effect of how the different operating systems handle networking events as it pertains to the `cqueues` dependency

# Usage
\<**TODO:** Something something run with OBS or command line params/env file (looks for OBS lua, else looks for env file, else looks for anything defined with params. Said params override OBS settings/env options.)\>

# Overview
\<**TODO:** Explain the components, how the server is the hub for all external connections, and how any webpage should connect to it via `wss://localhost`.\>

The websocket between the server and connected pages will contain a unified event stream, such that each indiviual page need only make one websocket connection. All of said functionality takes place within the provided javascript scripts.

