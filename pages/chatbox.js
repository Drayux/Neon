// -- TENOR INTEGRATION --
const TENORKEY = "sorry not for you :)";
const TENORCLIENT = "neon-chatbox";

// Returns a JSON object of X results matching the search query
// Each entry is a "Response Object" which contains a link to every available format
// https://developers.google.com/tenor/guides/response-objects-and-errors#response-object
async function tenorSearch(query) {
    if (typeof(query) != "string") {
        // TODO: Consider querying trending instead
        console.warn("Invalid tenor query");
        return null;
    }

    let response = await fetch(
        "https://tenor.googleapis.com/v2/search"
        + "?key=" + TENORKEY
        + "&client_key=" + TENORCLIENT
        + "&q=" + query
        + "&contentfilter=low"
        + "&media_filter=tinygif,tinygif_transparent,gif,gif_transparent"
        + "&ar_range=wide"
        + "&random=true"
        + "&limit=20"
    )

    if (response.status != 200) return null;
    return response.json();
}

async function tenorPosts(id) {
    if (typeof(id) != "string") {
        console.warn("Invalid tenor image ID");
        return null;
    }

    let response = await fetch(
        "https://tenor.googleapis.com/v2/posts"
        + "?key=" + TENORKEY
        + "&ids=" + id
    )

    return await response.json();
}

// -- IRC MESSAGE PARSING --
// Adapted from https://dev.twitch.tv/docs/irc/example-parser/
function parseMessage(data) {
    let ret = {};

    let idx = 0;
    let end = 0;

    // Message tags (begins with @ and appears to always be first, if present)
    if (data[idx] === '@') {
        end = data.indexOf(' ');
        let tagsarr = data.slice(1, end).split(';');
        idx = end + 1;

        // Tags are key/value pairs
        let tags = {}
        tagsarr.forEach(e => {
            let tag = e.split('=');
            // The javascript console will show inconsistent quote formatting
            // However, this is merely a werid side-effect if the keys have a hyphen character
            // The object is, in fact, properly formatted
            tags[tag[0]] = (tag[1] === '') ? null : tag[1];

            // At this point, the twitch code further parses the badges/emotes lists
            // My implementation moves this to a different function that handles a dict of emotes
        });

        ret.tags = tags;
    }

    // Message source (IRC host, receiver of the message, etc.; Often but not always present)
    if (data[idx] === ':') {
        idx += 1;
        end = data.indexOf(' ', idx);
        let sourcearr = data.slice(idx, end).split('!');
        idx = end + 1;

        // Source is either `nick!host` or just `host`
        let source = {
            nick: null,
            host: null
        };

        if (sourcearr.length == 2) {
            source.nick = sourcearr[0];
            source.host = sourcearr[1];
        } else source.host = sourcearr[0];

        ret.source = source; 
    }

    // Message command (PING, PRIVMSG, etc.; always present)
    end = data.indexOf(':', idx);
    if (end == -1) end = data.length;
    // It appears that the parameters component is not necessarily space-demlimited, so we jump to the colon and cut any extra spaces if present
    let commandarr = data.slice(idx, end).trim().split(' ');
    idx = end + 1;

    // Command comes in multiple parts: TYPE, CHANNEL*, ACK*
    ret.command = {
        type: commandarr[0],
        channel: (commandarr.length > 1) ? commandarr[1] : null,
        ack: (commandarr.length > 2) ? commandarr[2] : null
    }

    // Command params
    if (idx < data.length) ret.params = data.slice(idx).trim();

    return ret;
}

// -- IRC MESSAGE HANDLING --
// Expects an object built by parseMessage()
async function handleMessage(ircmsg, irc) {
    let command = ircmsg.command;
    if (!command) return;

    switch (command.type) {
        case "PING":
            keepAlive = "PONG :$".replace('$', ircmsg.params);
            irc.send(keepAlive);

            let date = new Date();
            let datestr = "[" + date.getHours() + ":" + date.getMinutes() + ":" + date.getSeconds() + "] ";

            console.log(datestr + "Replied to keep alive ping with '" + keepAlive + "'")
            break;

        case "USERNOTICE":
            console.log(ircmsg.command + ": " + ircmsg.params);
            break;

        case "PRIVMSG":
            /*/ This is the structure by which chat elements are generated
            / / Many of these elements are copied over directly from the parsed IRC string
                format = {
                    name: <The name associated with the message>
                    id: <Message ID (if applicable)>
                    host: <The "host" associated with the message (currently used for replies)>
                    content: <The message contents (string or array; emotes prefixed with "\!" )>
                    reply: <The message context (reply contents as a string)>
                    color: <The color in which the message's theme should be rendered>
                    alert: <Should the message take the form of an alert (no title/border)>
                    error: <Is this an error message>
                    command: <Is this message a command>
                    _ref: <Reference to the HTML document element, appended by CHATLOG.generate()>
                }   */
            let format = {};
            if (CHATLOG.docref) formatChat(format, ircmsg);

            // Ignore messages from specified usernames
            // (TODO: This could use a refactor to easily support a list of names -- Probably use a dict for name lookup)
            if (format.name.toUpperCase() == "NIGHTBOT") break;

            // Run any chat commands
            // TODO: Consider a way for bot messages to parse emotes
            // NOTE: Handle messages will never await if the message is not a command, so the
            //       message order should be determinstic if I understand the event queue correctly
            let botspeak = (format.command) ? await handleCommands(format) : null;
            if (botspeak) irc.send("PRIVMSG $1 :$2"
                .replace('$1', command.channel)
                .replace('$2', botspeak)
            );
        
            if (format.command) break;     // handleCommands() will reset this if we should output
            CHATLOG.generate(format);
            // console.log(format);
            break;

        case "WHISPER":
            // TODO: This could be used for a link approval system
            console.warn("TODO: Bot whisper functionality! ($)".replace('$', ircmsg.params));
            break;

        case "CLEARCHAT":
        case "CLEARMSG":
        case "GLOBALUSERSTATE":
        case "HOSTTARGET":
        case "NOTICE":
        case "ROOMSTATE":
        case "USERSTATE":
            console.log("TODO: " + ircmsg);
            break;
        
        case "RECONNECT":
            if (irc.sock) irc.sock.close();             // Will begin a reconnect via the onclose event handler
            break;
    }
}

// -- CHAT GENERATOR FORMATTING --
// Expects a reference to a chat format object
function formatChat(format, ircmsg) {
    if (!ircmsg) return;
    if (!format) format = {};

    let content = ircmsg.params;
    format.name = (ircmsg.tags["display-name"]) ? ircmsg.tags["display-name"] : ircmsg.source.nick;
    format.id = (ircmsg.tags.id) ? ircmsg.tags.id : null;

    // -- COLOR THEME (+IMAGE EMBEDS) --
    // Picks the closest color from a specified pallete
    // Users are gray if their color is unspecified
    let uHue = -1;      // Hue --> (uHue < 0) ? 0 : uHue * 60;
    let palette = [
        "--gAccentColorGray",
        "--gAccentColorRed",
        "--gAccentColorOrange",
        "--gAccentColorYellow",
        "--gAccentColorLime",
        "--gAccentColorGreen",
        "--gAccentColorMint",
        "--gAccentColorTeal",
        "--gAccentColorBlue",
        "--gAccentColorPurple",
        "--gAccentColorLavender",
        "--gAccentColorPink",
        "--gAccentColorBlush"
    ];

    let tagColor = ircmsg.tags.color;
    if (!tagColor) tagColor = format.name;
    else if (tagColor.length != 7) {
        console.warn("IRC color does not match expected format '$'".replace('$', tagColor));
        tagColor = null;
    }

    let hue = getColorHue(tagColor);
    let coloridx = -1;      // Gray is "hidden" color at 0th index

    // Select a color (via index) based upon the hue
    if (hue >= 0) {
        let paletteSize = (palette.length - 1 > 0) ? (palette.length - 1) : 1;
        let stepsize = 360 / (paletteSize);
        coloridx = Math.floor((hue + stepsize / 2) / stepsize);
        coloridx = coloridx % paletteSize;  // Catch those last 15 hue values that would wrap around
    }
    format.color = palette[coloridx + 1];

    /* ...
    if (!format.background) {
        // Background will be a tenor ID (for now)
        // TODO: Parse the ID into a working link
    }
    ... */

    // -- REPLY HANDLING --
    // Currently this intentionally does not parse emojis (consistent with the IRC protocol provided by Twitch)
    // To enable this, I should change my queue to handle some 100 messages and pull the content data via message ID
    let replyName = ircmsg.tags["reply-parent-display-name"];
    let replyContext = ircmsg.tags["reply-parent-msg-body"];
    let replyOffset = 0;
    if (replyName && replyContext) {
        format.host = replyName;
        format.reply = replyContext.replace(/\\s/gi, " ");

        replyOffset = content.indexOf(' ') + 1;
        content = content.substr(replyOffset);     // Remove the leading @username
    }

    // -- COMMAND CHECK --
    // All of the relevant command information is parsed at this point
    if (content[0] == '!') {
        let end = content.indexOf(' ');
        if (end < 1) end = content.length;
        format.command = content.slice(1, end).toUpperCase();
        format.content = content.slice(end + 1, content.length).trim();
        return format;
    }

    // -- EMOJI HANDLING --
    // TODO: --> function(content, emotestr, offset = 0) { ... }
    //           Returns string if no emotes, or parsed array
    if (!ircmsg.tags.emotes) {
        // No emojis to parse
        format.content = content;
        return format;
    }

    // Parse the emotes tag
    let emotelist = []
    ircmsg.tags.emotes.split('/').forEach(e => {
        /*if (emotedata.length < 2) {
            console.warn("'$' appears to be an incorrectly-formatted emote!".replace('$', e));
            return data;
        } */

        let emotedata = e.split(':');
        let emoteoccr = emotedata[1].split(",");
        emoteoccr.forEach(f => {
            let range = f.split("-");
            let emote = {
                id: emotedata[0],
                start: Number(range[0]) - replyOffset,
                end: Number(range[1]) - replyOffset
            };

            emotelist.push(emote)
        });
    });
    emotelist.sort(function(a, b) { return a.start - b.start });
    emotelist.push({ start: content.length, end: -1 });     // Ensures the last string will be appended

    // Split the message into of an array of strings and emote IDs
    let idx = 0;
    format.content = [];
    emotelist.forEach(e => {
        // Append the message section
        let sub = content.slice(idx, e.start).trim();
        if (sub.length > 0) format.content.push(sub);

        // Append the emote
        if (e.end < 0) return;   // Skip
        format.content.push("\\!" + e.id);
        idx = e.end + 1;
    });

    return format;
}

// -- CHAT COMMAND HANDLING --
// Returns message to be said by the bot or null (twitch does not echo bot messages to self)
async function handleCommands(format) {
    // TODO: For more complex command parsing, we can import a table of command names
    //       and their functionality and iterate through them (they should take the
    //       content string and the format ref as inputs, returning a boolean*)
    // TODO: Further, for regex matching we could build a list of "regex objects" where
    //       we would attempt to match everything in the list, excecuting their block
    //       if it's a match--returns true if we should continue matching
    // TODO: Finally, instead consider tokenizing the parameter string, using a
    //       transition table type of method (the option I decide should depend upon
    //       just what chat functionality I'd prefer the bot to have--currently unknown)
    switch (format.command) {
        case "GIF":
            // TODO: This probably needs a cooldown functionality....
            // Gif functionality won't work if there exists no tenor API key
            if (!TENORKEY) {
                console.warn("No tenor API key -- GIF functionality will not work");
                return null;
            }

            if (!format.content) {
                // User typed just "!gif"
                return "@$ -- Please enter a search query!"
                    .replace('$', format.name);
            }

            // Try to determine if the user typed a media ID or a search query
            let isTenorID = /^\d+$/.test(format.content);
            if (isTenorID) {
                console.warn("TODO: Tenor lookup via ID! (Needs a way to filter content...)");
                return null;
            }

            let response = await tenorSearch(format.content);
            if (!response) {
                console.warn("Tenor API response was null :(");
                return null;
            }

            for (i = 0; i < response.results.length; i++) {
                let formats = response.results[i].media_formats;
                let source = null;

                if (formats.tinygif_transparent) source = formats.tinygif_transparent.url;
                else if (formats.tinygif) source = formats.tinygif.url;
                else if (formats.gif_transparent) source = formats.gif_transparent.url;
                else if (formats.gif) source = formats.gif.url;

                if (!source) continue;

                // format.background = "https://media.tenor.com/P7hCyZlzDH4AAAAC/wink-anime.gif";
                format.background = source;
                break;
            }

            if (!format.background) {
                console.log("No results for query: " + format.content);
                return null;
            }

            format.content = null;      // If we ever want overlay text...
            format.command = null;      // Must be null or we won't see the GIF!
            return null;                // Bot will not say anything about the gif

        case "ONLYFANS":
            let botspeak = format.name + " is horny!";
            format.content = botspeak;
            format.alert = true;
            format.command = null;      // A message box should be generated

            // return botspeak;         // The bot should say something
            return null;                // The bot will not say anything
        
        default: console.log("Unrecognized command: '$'".replace('$', format.command));
    }

    return null;
}

// Escapes HTML-specific taglines to prevent users from injecting code into their chats
function scrubHTML(string) {
    if (!string) return null;
    let ret = string.replace(/<|>|&/gi, function (x) {
        switch (x) {
            case '<': return '&lt;';
            case '>': return '&gt;';
            case '&': return '&lt;';
        }
    })
    return ret;
}

// Gets a hue from a string
// Returns the actual hue if the string is a color string (ex. #551bdf)
// Returns hashed color if the string is generic (ex. "drayux")
// Returns -1 if hex string is gray or invalid
function getColorHue(colorString) {
    if (!colorString) return -1;
    if (colorString[0] != "#") {
        let hashval = 0;
        for (i = 0; i < colorString.length; i++)
            hashval += colorString.charCodeAt(i);
        return hashval % 360;
    }

    colorString = colorString.substr(1);

    let compLen = Math.floor(colorString.length / 3);
    let color = [
        Number("0x" + colorString.substr(0, compLen)) / 255,
        Number("0x" + colorString.substr(compLen, compLen)) / 255,
        Number("0x" + colorString.substr(2 * compLen, compLen)) / 255
    ];

    // Check for NaN
    for (i = 0; i < color.length; i++)
        if (!(color[i] < 256)) return -1;

    // Compute minimum and maximum values
    let min = 1;
    let max = 0;
    color.forEach(e => min = (min < e) ? min : e);
    color.forEach(e => max = (max < e) ? e : max);

    // Check for gray (divide by zero)
    if (min == max) return -1;

    let red = color[0];
    let green = color[1];
    let blue = color[2];

    let uHue = 0;
    if (max == red) uHue = (green - blue) / (max - min);             // -1.0 -> 1.0
    else if (max == green) uHue = 2 + (blue - red) / (max - min);    //  1.0 -> 3.0
    else uHue = 4 + (red - green) / (max - min);                      //  3.0 -> 5.0

    uHue = (uHue + 6) % 6;      // Normalize to [0, 6)
    return uHue * 60;           // Scale to [0, 360)
}

// Returns a generic (insecure) hash of a string with range [0, 360)
function colorHash(s) {
    
}

// Circular queue type for handling chat messages
// This performs the actual addition and removal subroutine
// (TODO: https://stackoverflow.com/questions/5525071/how-to-wait-until-an-element-exists)
const CHATLOG = {
    docref: null, //document.getElementById("chatbox"), // Reference to the chat container 
    data: null,
    size: 0,
    index: 0,
    pending: 0,
    
    _init(s = 10) {
        if (s < 1) return;
        if (this.data) this.clear();
        this.size = s;
        this.data = [];
        while (s--) this.data.push(null);

        // Find the element if available
        if (!this.docref) {
            let chatbox = new Promise(resolve => {
                if (document.querySelector("#chatbox"))
                    return resolve(document.querySelector("#chatbox"));

                const observer = new MutationObserver(mutations => {
                    if (document.querySelector("#chatbox")) {
                        observer.disconnect();
                        resolve(document.querySelector("#chatbox"));
                    }
                });

                observer.observe(document.body, {
                    childList: true,
                    subtree: true
                });
            });

            // To add an error type, we want to make two sub-sections: messages, and error
            // Create those elements in this callback and replace docref with a reference to either element
            chatbox.then(res => this.docref = res);
        }
    },

    // Insert expects the format structure generated by formatChat() -> this.generate()
    _insert(x) {
        this.pending -= 1;
        if (!this.docref) return null;

        // Remove the current element
        const prev = this.data[this.index];
        this._remove(prev);

        // Insert the new element
        this.data[this.index] = x;
        this.index = (this.index + 1) % this.size;

        // Put new message into the HTML document
        let ref = x._ref;
        this.docref.appendChild(ref);
        return ref;
    },

    // Delete a specified element from the document
    // x is the format element as saved in the local data array
    // returns false if no element was deleted
    _remove(x) {
        if (!x || !x._ref) return false;
        // x._ref.parentNode.removeChild(x._ref);
        this.docref.removeChild(x._ref);
        x._ref = null;
        return true;
    },

    // Clear all messages from the chat box
    clear() {
        this.index = 0;
        for (i = 0; i < this.data.length; i++) {
            let element = this.data[i];
            this._remove(element);
        }
    },

    // Delete chats matching the specific condition
    // NOTE: To avoid the (albeit rare) possiblity of a user becoming banned, clearing their messages
    //       and then the currently generating chat still appearing afterwards, we are exploting
    //       some caveats of the event queue by incrementing the number of pending messages at the start
    //       of generate() and decrementing at the end (in _insert()).
    delete(user = null, id = null) {
        let self = this;

        // Once pending is 0, we've guaranteed every message before this command has been generated
        async function waitPending() {
            let attempts = 0;
            while (true) {
                // By awaiting a new promise, we are sending this execution to the end of the
                // end of the event queue. We won't loop again until the event queue has finished
                // resolving the original promise. A weird caveat however, is that console input
                // (in firefox at least) appears to be a lower priority, so this loops indefinitely
                // (barring the attempt catch) if we try to override self.pending in the console.

                let pendingCount = await Promise.resolve(self.pending);
                if (pendingCount == 0) return true;

                // This should probably never happen
                else if (pendingCount < 0 || attempts > 10) {
                    console.warn("Stopped waitPending() from an infinite loop -- pendingCount = " + pendingCount);
                    return false;
                }
                attempts += 1;
            }
        }
        
        waitPending().then((ret) => {
            let username = user.toLowerCase();
            for (i = 0; i < self.data.length; i++) {
                let element = self.data[i];
                if (!element) continue;

                // Remove the chat under these conditions
                if (element.name.toLowerCase() === username || element.id === id)
                    self._remove(element);

                // Alternatively just remove the reply
                // NOTE: Currently this will not work if the message was removed by ID
                else if (element.host && element.host.toLowerCase() == username)
                    element._ref.querySelector(".reply").innerHTML = "&lt; Message removed &gt;"
            }
        });
    },

    // Generate an element with support for various formats
    // Content is a formatted dictionary from which the block structure will be generated
    // (Successor to the original addChat and addAlert functions)
    generate(format) {
        if (!format) return null;
        this.pending += 1;

        // Parent chat element
        const _chat = document.createElement("div");
        _chat.classList.add("chat");
        if (format.id) _chat.id = format.id;
        format._ref = _chat;

        const _title = document.createElement("div");
        _title.classList.add("title");

        const _content = document.createElement("div");
        _content.classList.add("content");
        
        // -- Content portion --
        if (format.reply) {
            const _reply = document.createElement("span")
            _reply.classList.add("reply");
            _reply.innerHTML = scrubHTML(format.reply);
            _content.appendChild(_reply);
        }

        // For error messages, add the check here
        // Instead of this._insert, just add it to this.errorref directly as we store a maximum
        // of one child element (but don't forget to erase the original)
        // Finally, we want one more member function "clearError()"
        // Alternatively create a new member: "generateError()"

        let textCount = 0;
        let emoteCount = 0;
        let chatContent = (typeof(format.content) == "string") ? [ format.content ] : format.content;
        let contentLength = (chatContent) ? chatContent.length : 0;
        for (i = 0; i < contentLength; i++) {
            let part = chatContent[i];
            let elementType = "span";
            let elementClass = "message";

            if (part.length > 2 && (part.substr(0, 2) == "\\!")) {
                // Message part is an emote
                elementType = "img";
                elementClass = "emote";
                emoteCount += 1;
            } else textCount += 1;

            const _message = document.createElement(elementType);
            _message.classList.add(elementClass);
            // TODO: Consider using srcset for the 3.0 resolution
            if (elementClass == "emote")
                _message.src = "https://static-cdn.jtvnw.net/emoticons/v2/$/default/dark/2.0"
                    .replace('$', part.substr(2));
            else _message.innerHTML = scrubHTML(part);

            _content.appendChild(_message);
        };

        if (contentLength && !textCount) _content.classList.add("emoteonly");

        if (!format.alert) _chat.appendChild(_title);
        _chat.appendChild(_content);        // if (contentLength) ...
        if (format.background) {
            // Create a new element that will sit under the chat box
            const _background = document.createElement("div");
            _background.classList.add("background");
            
            // if (format.background[0] == '#') _background.style.cssText += "--background: $;".replace('$', format.background);
            _chat.style.cssText += "--background: url($);".replace('$', format.background);
            _chat.appendChild(_background);
        }

        if (format.alert) {
            // We are done if this is an alert
            _chat.classList.add("alert");
            return this._insert(format);
        }

        if (format.background) _chat.classList.add("image");
        else if (textCount || emoteCount > 8) _chat.classList.add("text");      // Small
        else _chat.classList.add("react");  // ( else if (!textCount) ... )     // Large

        // -- Title portion --
        if (format.name) {
            const _name = document.createElement("span");
            _name.classList.add("name");
            _name.innerHTML = format.name;     // Hopefully this doesn't need to be scrubbed?
            _title.appendChild(_name);
        }

        if (format.host) {
            const _host = document.createElement("span");
            _host.classList.add("host");
            _host.innerHTML = format.host;     // Same with this one??
            _title.appendChild(_host);
        }

        // -- Extra styling (via CSS vars) --
        // Accent color
        if (format.color) {
            _chat.style.cssText += (format.color[0] == "#") ?
                "--color: $;".replace('$', format.color) :
                "--color: var($);".replace('$', format.color);
        }

        // if (format.background) _chat.style.cssText += "--backgroundImage: url($);".replace('$', format.background);

        // Add the content to the page
        return this._insert(format);
    }
};

const IRC = {
    sock: null,
    timeout: 1000,      // 1 second
    reconnect: false,
    raw: false,         // window.location.hash.toLowerCase() == "#raw" ? true : false;

    // TODO: I believe it is possible (albeit rare) that multiple _init routines are
    //       running simultaneously, potentially leading to a connection error (good end)
    //       or multiple connections open at once (meaning duplicate messages) if the
    //       connect method is called more than once.

    // IMPL: A fix involving mutexes or some form of local asynchronous event queue should
    //       be considered as a solution to this problem. Further, observe that in rare cases,
    //       calling the disconnect function may also fail to stop the server if a reconnect
    //       routine is happening, as a new server will be started after calling disconnect.

    // NOTE: Upon further inspection, stackoverflow reports that "javascript is never 
    //       multithreaded" and testing shows that event callbacks are only ever processed
    //       after synchronous code. It would seem that this is not an issue afterall, but
    //       sufficient testing is necessary.

    _init(self) {
        if (self.sock) self.sock.close();
        let twitchsock = new WebSocket("wss://irc-ws.chat.twitch.tv:443");
        self.sock = twitchsock;

        // Close the socket on error
        twitchsock.addEventListener("error", (event) => {
            console.warn("Connection failed with IRC socket")

            // let format = {
            //     name: null,
            //     host: "twitch",
            //     content: "ERROR: BAD CONNECTION WITH IRC SOCKET",
            //     error: true
            // }
            // CHATLOG.generate(format);    // Alternatively "generateError()"
            
            twitchsock.close();
        });

        // Parse and handle IRC messages
        twitchsock.addEventListener("message", (event) => {
            event.data.split('\n').forEach(e => {
                if (e.length == 0) return;
                let ircmsg = parseMessage(e);
                // console.log(ircmsg);     // DEBUG: Show the raw IRC message string
                handleMessage(ircmsg, twitchsock);
            });
        });

        // Submit authentication and channel details upon opening
        twitchsock.addEventListener("open", (event) => {
            console.log("Websocket successfully established connection");
            self.timeout = 1000;      // Attempt successful, reset the retry timeout

            twitchsock.send("PASS oauth:also not for you");
            twitchsock.send("NICK good luck!");
            twitchsock.send("JOIN #your channel owo");

            self.sock.send("CAP REQ :twitch.tv/commands");
            self.sock.send("CAP REQ :twitch.tv/tags");
        });

        // Attempt to reconnect upon close
        twitchsock.addEventListener("close", (event) => {
            if (!self.reconnect || self.timeout > 100000) {
                console.log("Websocket will not try to reconnect");

                self.timeout = 1000;  // Don't worry about backoff if we're giving up
                self.reconnect = false;
                return;
            }

            setTimeout(() => {
                self.timeout *= 1.5;    // Originally preferred 2x, however the websocket times out slowly

                // Calling the member function from an event listener will bind
                // 'this' to the window object, not the object associated with the function
                // so we need to pass in a reference to itself
                self._init(self);
                
            }, self.timeout);
        });
    },

    connect() {
        this._init(this);
        this.reconnect = true;
    },

    disconnect() {
        this.reconnect = false;
        if (this.sock) this.sock.close();
    }
};

function initChatbox() {
    // TODO: Parse chatbox params from URL query
    // raw -> raw IRC output
    // commands -> list of commands to enable (unmatched commands have no effect)

    CHATLOG._init();
    IRC.connect();
}
