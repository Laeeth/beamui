/**
Text style properties.

Copyright: dayllenger 2019
License:   Boost License 1.0
Authors:   dayllenger
*/
module beamui.text.style;

import beamui.core.editable : TabSize;
import beamui.graphics.colors : Color;
import beamui.text.fonts : Font;

/// Specifies text alignment
enum TextAlign : ubyte
{
    start,
    center,
    end,
    justify
}

/// Decoration added to text (like underline)
struct TextDecoration
{
    enum Line : ubyte
    {
        none,
        overline,
        underline,
        lineThrough
    }
    enum Style : ubyte
    {
        solid,
        doubled,
        dotted,
        dashed,
        wavy
    }
    alias none = Line.none;
    alias overline = Line.overline;
    alias underline = Line.underline;
    alias lineThrough = Line.lineThrough;
    alias solid = Style.solid;

    Color color;
    Line line;
    Style style;
}

/// Controls how text with `&` hotkey marks should be displayed
enum TextHotkey : ubyte
{
    /// Treat as usual text
    ignore,
    /// Only hide `&` marks
    hidden,
    /// Underline hotkey letter that goes after `&`
    underline,
    /// Underline hotkey letter that goes after `&` only when Alt pressed
    underlineOnAlt
}

/// Specifies how text that doesn't fit and is not displayed should behave
enum TextOverflow : ubyte
{
    clip,
    ellipsis,
    ellipsisMiddle
}

/// Controls capitalization of text
enum TextTransform : ubyte
{
    none,
    capitalize,
    uppercase,
    lowercase
}

/// Holds text properties - font style, colors, and so on
struct TextStyle
{
    /// Font that also contains size, style, weight properties
    Font font;
    /// Size of the tab character in number of spaces
    TabSize tabSize;
    TextAlign alignment;
    TextDecoration decoration;
    TextHotkey hotkey;
    TextOverflow overflow;
    TextTransform transform;
    /// Text foreground color
    Color color;
    /// Text background color
    Color background;
}

/// Holds properties of the text, that influence only its layout
struct TextLayoutStyle
{
    TabSize tabSize;
    TextTransform transform;
    bool skipHotkeyMarks;

    this(ref const TextStyle superStyle)
    {
        tabSize = superStyle.tabSize;
        transform = superStyle.transform;
        skipHotkeyMarks = superStyle.hotkey != TextHotkey.ignore;
    }
}