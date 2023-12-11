function toRGB(hex) {
    if (hex.length != 7) return null;
    let R = hex.substr(1, 2);
    let G = hex.substr(3, 2);
    let B = hex.substr(5, 2);

    return {
        r: Number("0x" + R),
        g: Number("0x" + G),
        b: Number("0x" + B)
    }
}

function calcHue(rgb) {
    let hue = -1;
    let R = rgb.r / 255;
    let G = rgb.g / 255;
    let B = rgb.b / 255;

    if (R == G && G == B) return hue;

    let minVal = 1;
    let maxVal = 0;

    [R, G, B].forEach(e => minVal = (minVal < e) ? minVal : e);
    [R, G, B].forEach(e => maxVal = (maxVal < e) ? e : maxVal);

    // console.log("max " + maxVal);
    // console.log("min " + minVal);

    if (maxVal == R) hue = (G - B) / (maxVal - minVal);
    else if (maxVal == G) hue = 2 + (B - R) / (maxVal - minVal);
    else hue = 4 + (R - G) / (maxVal - minVal);

    hue *= 60;
    return (hue < 0) ? hue + 360 : hue;
}

function closestColor(hue, steps = 12) {
    if (hue < 0) return 0;      // Gray

    let stepsize = 360 / steps;
    let idx = (hue + (stepsize / 2)) / stepsize;

    return Math.floor(idx) + 1;
}

function setColor(idx) {
    const _body = document.querySelector("body");
    if (!_body) {
        console.log("Could not find page body :(");
        return;
    }

    let palette = [
        "hsl(0, 0%, 50%)",
        "hsl(0, 70%, 70%)",
        "hsl(30, 70%, 70%)",
        "hsl(60, 70%, 70%)",
        "hsl(90, 70%, 70%)",
        "hsl(120, 70%, 70%)",
        "hsl(150, 70%, 70%)",
        "hsl(180, 70%, 70%)",
        "hsl(210, 70%, 70%)",
        "hsl(240, 70%, 70%)",
        "hsl(270, 70%, 70%)",
        "hsl(300, 70%, 70%)",
        "hsl(330, 70%, 70%)"
    ]

    _body.style.cssText = "background-color: $;".replace('$', palette[idx]);
}

function preview(color) {
    let rgb = toRGB(color);
    let hue = calcHue(rgb);
    let idx = closestColor(hue);
    setColor(idx);
}
