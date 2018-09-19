/**
This module contains implementation of editors.


EditLine - single line editor.

EditBox - multiline editor

LogWidget - readonly text box for showing logs

Synopsis:
---
import beamui.widgets.editors;
---

Copyright: Vadim Lopatin 2014-2017, James Johnson 2017
License:   Boost License 1.0
Authors:   Vadim Lopatin
*/
module beamui.widgets.editors;

public import beamui.core.editable;
import beamui.core.collections;
import beamui.core.linestream;
import beamui.core.parseutils : isWordChar;
import beamui.core.signals;
import beamui.core.stdaction;
import beamui.core.streams;
import beamui.graphics.colors;
import beamui.widgets.controls;
import beamui.widgets.layouts;
import beamui.widgets.menu;
import beamui.widgets.popup;
import beamui.widgets.scroll;
import beamui.widgets.widget;
import beamui.platforms.common.platform;

/// Editor state to display in status line
struct EditorStateInfo
{
    /// Editor mode: true if replace mode, false if insert mode
    bool replaceMode;
    /// Cursor position column (1-based)
    int col;
    /// Cursor position line (1-based)
    int line;
    /// Character under cursor
    dchar character;
    /// Returns true if editor is in active state
    @property bool active()
    {
        return col > 0 && line > 0;
    }
}

/// Flags used for search / replace / text highlight
enum TextSearchFlag
{
    caseSensitive = 1,
    wholeWords = 2,
    selectionOnly = 4,
}

/// Delete word before cursor (ctrl + backspace)
Action ACTION_ED_DEL_PREV_WORD;
/// Delete char after cursor (ctrl + del key)
Action ACTION_ED_DEL_NEXT_WORD;

/// Indent text block or single line (e.g., Tab key to insert tab character)
Action ACTION_ED_INDENT;
/// Unindent text or remove whitespace before cursor (usually Shift+Tab)
Action ACTION_ED_UNINDENT;

/// Insert new line before current position (Ctrl+Shift+Enter)
Action ACTION_ED_PREPEND_NEW_LINE;
/// Insert new line after current position (Ctrl+Enter)
Action ACTION_ED_APPEND_NEW_LINE;
/// Delete current line
Action ACTION_ED_DELETE_LINE;
/// Turn On/Off replace mode
Action ACTION_ED_TOGGLE_REPLACE_MODE;

/// Toggle line comment
Action ACTION_ED_TOGGLE_LINE_COMMENT;
/// Toggle block comment
Action ACTION_ED_TOGGLE_BLOCK_COMMENT;
/// Toggle bookmark in current line
Action ACTION_ED_TOGGLE_BOOKMARK;
/// Move cursor to next bookmark
Action ACTION_ED_GOTO_NEXT_BOOKMARK;
/// Move cursor to previous bookmark
Action ACTION_ED_GOTO_PREVIOUS_BOOKMARK;

/// Find text
Action ACTION_ED_FIND;
/// Find next occurence - continue search forward
Action ACTION_ED_FIND_NEXT;
/// Find previous occurence - continue search backward
Action ACTION_ED_FIND_PREV;
/// Replace text
Action ACTION_ED_REPLACE;

void initStandardEditorActions()
{
    ACTION_ED_DEL_PREV_WORD = new Action(null, KeyCode.backspace, KeyFlag.control);
    ACTION_ED_DEL_NEXT_WORD = new Action(null, KeyCode.del, KeyFlag.control);

    ACTION_ED_INDENT = new Action(null, KeyCode.tab);
    ACTION_ED_UNINDENT = new Action(null, KeyCode.tab, KeyFlag.shift);

    ACTION_ED_PREPEND_NEW_LINE = new Action(tr("Prepend new line"d), KeyCode.enter, KeyFlag.control | KeyFlag.shift);
    ACTION_ED_APPEND_NEW_LINE = new Action(tr("Append new line"d), KeyCode.enter, KeyFlag.control);
    ACTION_ED_DELETE_LINE = new Action(tr("Delete line"d), KeyCode.D, KeyFlag.control).addShortcut(KeyCode.L, KeyFlag.control);
    ACTION_ED_TOGGLE_REPLACE_MODE = new Action(tr("Replace mode"d), KeyCode.ins);
    ACTION_ED_TOGGLE_LINE_COMMENT = new Action(tr("Toggle line comment"d), KeyCode.divide, KeyFlag.control);
    ACTION_ED_TOGGLE_BLOCK_COMMENT = new Action(tr("Toggle block comment"d), KeyCode.divide, KeyFlag.control | KeyFlag.shift);

    ACTION_ED_TOGGLE_BOOKMARK = new Action(tr("Toggle bookmark"d), KeyCode.B, KeyFlag.control | KeyFlag.shift);
    ACTION_ED_GOTO_NEXT_BOOKMARK = new Action(tr("Go to next bookmark"d), KeyCode.down, KeyFlag.control | KeyFlag.shift | KeyFlag.alt);
    ACTION_ED_GOTO_PREVIOUS_BOOKMARK = new Action(tr("Go to previous bookmark"d), KeyCode.up, KeyFlag.control | KeyFlag.shift | KeyFlag.alt);

    ACTION_ED_FIND = new Action(tr("Find..."d), KeyCode.F, KeyFlag.control);
    ACTION_ED_FIND_NEXT = new Action(tr("Find next"d), KeyCode.F3, 0);
    ACTION_ED_FIND_PREV = new Action(tr("Find previous"d), KeyCode.F3, KeyFlag.shift);
    ACTION_ED_REPLACE = new Action(tr("Replace..."d), KeyCode.H, KeyFlag.control);

    bunch(
        ACTION_ED_DEL_PREV_WORD,
        ACTION_ED_DEL_NEXT_WORD,
        ACTION_ED_INDENT,
        ACTION_ED_UNINDENT,
    ).context(ActionContext.widget);
    bunch(
        ACTION_ED_PREPEND_NEW_LINE,
        ACTION_ED_APPEND_NEW_LINE,
        ACTION_ED_DELETE_LINE,
        ACTION_ED_TOGGLE_REPLACE_MODE,
        ACTION_ED_TOGGLE_LINE_COMMENT,
        ACTION_ED_TOGGLE_BLOCK_COMMENT,
        ACTION_ED_TOGGLE_BOOKMARK,
        ACTION_ED_GOTO_NEXT_BOOKMARK,
        ACTION_ED_GOTO_PREVIOUS_BOOKMARK,
        ACTION_ED_FIND,
        ACTION_ED_FIND_NEXT,
        ACTION_ED_FIND_PREV,
        ACTION_ED_REPLACE
    ).context(ActionContext.widgetTree);
}

/// Base for all editor widgets
class EditWidgetBase : ScrollAreaBase, ActionOperator
{
    @property
    {
        /// Editor content object
        EditableContent content()
        {
            return _content;
        }
        /// Set content object
        EditWidgetBase content(EditableContent content)
        {
            if (_content is content)
                return this; // not changed
            if (_content !is null)
            {
                // disconnect old content
                _content.contentChanged.disconnect(&onContentChange);
                if (_ownContent)
                {
                    destroy(_content);
                }
            }
            _content = content;
            _ownContent = false;
            _content.contentChanged.connect(&onContentChange);
            if (_content.readOnly)
                enabled = false;
            return this;
        }

        /// When true, Tab / Shift+Tab presses are processed internally in widget (e.g. insert tab character) instead of focus change navigation.
        bool wantTabs() const
        {
            return _wantTabs;
        }
        /// ditto
        EditWidgetBase wantTabs(bool wantTabs)
        {
            _wantTabs = wantTabs;
            return this;
        }

        /// Readonly flag (when true, user cannot change content of editor)
        bool readOnly() const
        {
            return !enabled || _content.readOnly;
        }
        /// ditto
        EditWidgetBase readOnly(bool readOnly)
        {
            enabled = !readOnly;
            invalidate();
            return this;
        }

        /// Replace mode flag (when true, entered character replaces character under cursor)
        bool replaceMode() const
        {
            return _replaceMode;
        }
        /// ditto
        EditWidgetBase replaceMode(bool replaceMode)
        {
            _replaceMode = replaceMode;
            handleEditorStateChange();
            invalidate();
            return this;
        }

        /// When true, spaces will be inserted instead of tabs on Tab key
        bool useSpacesForTabs() const
        {
            return _content.useSpacesForTabs;
        }
        /// ditto
        EditWidgetBase useSpacesForTabs(bool useSpacesForTabs)
        {
            _content.useSpacesForTabs = useSpacesForTabs;
            return this;
        }

        /// Tab size (in number of spaces)
        int tabSize() const
        {
            return _content.tabSize;
        }
        /// ditto
        EditWidgetBase tabSize(int newTabSize)
        {
            newTabSize = clamp(newTabSize, 0, 16);
            if (newTabSize != tabSize)
            {
                _content.tabSize = newTabSize;
                requestLayout();
            }
            return this;
        }

        /// True if smart indents are supported
        bool supportsSmartIndents() const
        {
            return _content.supportsSmartIndents;
        }
        /// True if smart indents are enabled
        bool smartIndents() const
        {
            return _content.smartIndents;
        }
        /// ditto
        EditWidgetBase smartIndents(bool enabled)
        {
            _content.smartIndents = enabled;
            return this;
        }

        /// True if smart indents are enabled
        bool smartIndentsAfterPaste() const
        {
            return _content.smartIndentsAfterPaste;
        }
        /// ditto
        EditWidgetBase smartIndentsAfterPaste(bool enabled)
        {
            _content.smartIndentsAfterPaste = enabled;
            return this;
        }

        /// When true allows copy / cut whole current line if there is no selection
        bool copyCurrentLineWhenNoSelection()
        {
            return _copyCurrentLineWhenNoSelection;
        }
        /// ditto
        EditWidgetBase copyCurrentLineWhenNoSelection(bool flag)
        {
            _copyCurrentLineWhenNoSelection = flag;
            return this;
        }

        /// When true shows mark on tab positions in beginning of line
        bool showTabPositionMarks()
        {
            return _showTabPositionMarks;
        }
        /// ditto
        EditWidgetBase showTabPositionMarks(bool flag)
        {
            if (flag != _showTabPositionMarks)
            {
                _showTabPositionMarks = flag;
                invalidate();
            }
            return this;
        }

        /// To hold _scrollpos.x toggling between normal and word wrap mode
        private int previousXScrollPos;
        /// True if word wrap mode is set
        bool wordWrap()
        {
            return _wordWrap;
        }
        /// Enable or disable word wrap mode
        EditWidgetBase wordWrap(bool v)
        {
            _wordWrap = v;
            // horizontal scrollbar should not be visible in word wrap mode
            if (v)
            {
                _hscrollbar.visibility = Visibility.invisible;
                previousXScrollPos = _scrollPos.x;
                _scrollPos.x = 0;
                wordWrapRefresh();
            }
            else
            {
                _hscrollbar.visibility = Visibility.visible;
                _scrollPos.x = previousXScrollPos;
            }
            invalidate();
            return this;
        }

        override dstring text() const
        {
            return _content.text;
        }

        override Widget text(dstring s)
        {
            _content.text = s;
            requestLayout();
            return this;
        }
    }

    /// Set bool property value, for ML loaders
    mixin(generatePropertySettersMethodOverride("setBoolProperty", "bool", "wantTabs",
            "showTabPositionMarks", "readOnly", "replaceMode",
            "useSpacesForTabs", "copyCurrentLineWhenNoSelection"));

    /// Set int property value, for ML loaders
    mixin(generatePropertySettersMethodOverride("setIntProperty", "int", "tabSize"));

    /// Modified state change listener (e.g. content has been saved, or first time modified after save)
    Signal!(void delegate(Widget source, bool modified)) modifiedStateChanged;

    /// Signal to emit when editor content is changed
    Signal!(void delegate(EditableContent)) contentChanged;

    /// Signal to emit when editor cursor position or Insert/Replace mode is changed.
    Signal!(void delegate(Widget, ref EditorStateInfo editorState)) stateChanged;

    protected
    {
        EditableContent _content;
        /// When _ownContent is false, _content should not be destroyed in editor destructor
        bool _ownContent = true;

        int _lineHeight;
        Point _scrollPos;
        bool _fixedFont;
        int _spaceWidth;

        // left pane - can be used to show line numbers, collapse controls, bookmarks, breakpoints, custom icons
        int _leftPaneWidth;

        int _minFontSize = -1; // disable zooming
        int _maxFontSize = -1; // disable zooming

        bool _wantTabs = true;

        bool _selectAllWhenFocusedWithTab;
        bool _deselectAllWhenUnfocused;

        bool _replaceMode;

        uint _selectionColorFocused = 0xB060A0FF;
        uint _selectionColorNormal = 0xD060A0FF;
        uint _searchHighlightColorCurrent = 0x808080FF;
        uint _searchHighlightColorOther = 0xC08080FF;

        uint _caretColor = 0x000000;
        uint _caretColorReplace = 0x808080FF;
        uint _matchingBracketHightlightColor = 0x60FFE0B0;

        /// When true, call measureVisibleText on next layout
        bool _contentChanged = true;

        bool _copyCurrentLineWhenNoSelection = true;

        bool _showTabPositionMarks;

        bool _wordWrap;
    }

    this(ScrollBarMode hscrollbarMode = ScrollBarMode.automatic,
         ScrollBarMode vscrollbarMode = ScrollBarMode.automatic)
    {
        super(hscrollbarMode, vscrollbarMode);
        focusable = true;
        bindActions();
    }

    /// Free resources
    ~this()
    {
        unbindActions();
        if (_ownContent)
        {
            destroy(_content);
            _content = null;
        }
    }

    //===============================================================
    // Focus

    override @property bool canFocus() const
    {
        // allow to focus even if not enabled
        return focusable && visible;
    }

    override Widget setFocus(FocusReason reason = FocusReason.unspecified)
    {
        Widget res = super.setFocus(reason);
        if (focused)
            handleEditorStateChange();
        return res;
    }

    override protected void handleFocusChange(bool focused, bool receivedFocusFromKeyboard = false)
    {
        if (focused)
            startCaretBlinking();
        else
        {
            stopCaretBlinking();
            cancelHoverTimer();

            if (_deselectAllWhenUnfocused)
            {
                _selectionRange.start = _caretPos;
                _selectionRange.end = _caretPos;
            }
        }
        if (focused && _selectAllWhenFocusedWithTab && receivedFocusFromKeyboard)
            selectAll();
        super.handleFocusChange(focused);
    }

    //===============================================================

    /// Updates `stateChanged` with recent position
    protected void handleEditorStateChange()
    {
        if (!stateChanged.assigned)
            return;
        EditorStateInfo info;
        if (visible)
        {
            info.replaceMode = _replaceMode;
            info.line = _caretPos.line + 1;
            info.col = _caretPos.pos + 1;
            if (_caretPos.line >= 0 && _caretPos.line < _content.length)
            {
                dstring line = _content.line(_caretPos.line);
                if (_caretPos.pos >= 0 && _caretPos.pos < line.length)
                    info.character = line[_caretPos.pos];
                else
                    info.character = '\n';
            }
        }
        stateChanged(this, info);
    }

    override protected void handleClientBoxLayout(ref Box clb)
    {
        updateLeftPaneWidth();
        clb.x += _leftPaneWidth;
        clb.w -= _leftPaneWidth;
    }

    /// Override for multiline editors
    protected int lineCount()
    {
        return 1;
    }

    //===============================================================
    // Dynamic word wrap implementation

    /// Override for EditBox
    void wordWrapRefresh()
    {
        return;
    }

    /// Characters at which content is split for word wrap mode
    dchar[] splitChars = [' ', '-', '\t'];

    /// Divides up a string for word wrapping, sets info in _span
    dstring[] wrapLine(dstring str, int lineNumber)
    {
        FontRef font = font();
        dstring[] words = explode(str, splitChars);
        int curLineLength = 0;
        dchar[] buildingStr;
        dstring[] buildingStrArr;
        WrapPoint[] wrapPoints;
        int wrappedLineCount = 0;
        int curLineWidth = 0;
        int maxWidth = clientBox.width;
        for (int i = 0; i < words.length; i++)
        {
            dstring word = words[i];
            if (curLineWidth + measureWrappedText(word) > maxWidth)
            {
                if (curLineWidth > 0)
                {
                    buildingStrArr ~= to!dstring(buildingStr);
                    wrappedLineCount++;
                    wrapPoints ~= WrapPoint(curLineLength, curLineWidth);
                    curLineLength = 0;
                    curLineWidth = 0;
                    buildingStr = [];
                }
                while (measureWrappedText(word) > maxWidth)
                {
                    //For when string still too long
                    int wrapPoint = findWrapPoint(word);
                    wrapPoints ~= WrapPoint(wrapPoint, measureWrappedText(word[0 .. wrapPoint]));
                    buildingStr ~= word[0 .. wrapPoint];
                    word = word[wrapPoint .. $];
                    buildingStrArr ~= to!dstring(buildingStr);
                    buildingStr = [];
                    wrappedLineCount++;
                }
            }
            buildingStr ~= word;
            curLineLength += to!int(word.length);
            curLineWidth += measureWrappedText(word);
        }
        wrapPoints ~= WrapPoint(curLineLength, curLineWidth);
        buildingStrArr ~= to!dstring(buildingStr);
        _span ~= LineSpan(lineNumber, wrappedLineCount + 1, wrapPoints, buildingStrArr);
        return buildingStrArr;
    }

    /// Divide (and conquer) text into words
    dstring[] explode(dstring str, dchar[] splitChars)
    {
        dstring[] parts;
        int startIndex = 0;
        import std.string : indexOfAny;

        while (true)
        {
            int index = to!int(str.indexOfAny(splitChars, startIndex));

            if (index == -1)
            {
                parts ~= str[startIndex .. $];
                debug (editors)
                    Log.d("Explode output: ", parts);
                return parts;
            }

            dstring word = str[startIndex .. index];
            dchar nextChar = (str[index .. index + 1])[0];

            import std.ascii : isWhite;

            if (isWhite(nextChar))
            {
                parts ~= word;
                parts ~= to!dstring(nextChar);
            }
            else
            {
                parts ~= word ~ nextChar;
            }
            startIndex = index + 1;
        }
    }

    /// Information about line span into several lines - in word wrap mode
    protected LineSpan[] _span;
    protected LineSpan[] _spanCache;

    /// Finds good visual wrapping point for string
    int findWrapPoint(dstring text)
    {
        int maxWidth = clientBox.width;
        int wrapPoint = 0;
        while (true)
        {
            if (measureWrappedText(text[0 .. wrapPoint]) < maxWidth)
            {
                wrapPoint++;
            }
            else
            {
                return wrapPoint;
            }
        }
    }

    /// Call measureText for word wrap
    int measureWrappedText(dstring text)
    {
        FontRef font = font();
        int[] measuredWidths;
        measuredWidths.length = text.length;
        //DO NOT REMOVE THIS
        int boggle = font.measureText(text, measuredWidths);
        if (measuredWidths.length > 0)
            return measuredWidths[$ - 1];
        return 0;
    }

    /// Returns number of visible wraps up to a line (not including the first wrapLines themselves)
    int wrapsUpTo(int line)
    {
        int sum;
        lineSpanIterate(delegate(LineSpan curSpan) {
            if (curSpan.start < line)
                sum += curSpan.len - 1;
        });
        return sum;
    }

    /// Returns LineSpan for line based on actual line number
    LineSpan getSpan(int lineNumber)
    {
        LineSpan lineSpan = LineSpan(lineNumber, 0, [WrapPoint(0, 0)], []);
        lineSpanIterate(delegate(LineSpan curSpan) {
            if (curSpan.start == lineNumber)
                lineSpan = curSpan;
        });
        return lineSpan;
    }

    /// Based on a TextPosition, finds which wrapLine it is on for its current line
    int findWrapLine(TextPosition textPos)
    {
        int curWrapLine = 0;
        int curPosition = textPos.pos;
        LineSpan curSpan = getSpan(textPos.line);
        while (true)
        {
            if (curWrapLine == curSpan.wrapPoints.length - 1)
                return curWrapLine;
            curPosition -= curSpan.wrapPoints[curWrapLine].wrapPos;
            if (curPosition < 0)
            {
                return curWrapLine;
            }
            curWrapLine++;
        }
    }

    /// Simple way of iterating through _span
    void lineSpanIterate(void delegate(LineSpan curSpan) iterator)
    {
        //TODO: Rename iterator to iteration?
        foreach (currentSpan; _span)
            iterator(currentSpan);
    }

    //===============================================================

    /// Override to add custom items on left panel
    protected void updateLeftPaneWidth()
    {
    }

    protected bool onLeftPaneMouseClick(MouseEvent event)
    {
        return false;
    }

    protected void drawLeftPane(DrawBuf buf, Rect rc, int line)
    {
        // override for custom drawn left pane
    }

    override bool canShowPopupMenu(int x, int y)
    {
        if (_popupMenu is null)
            return false;
        if (_popupMenu.openingSubmenu.assigned)
            if (!_popupMenu.openingSubmenu(_popupMenu))
                return false;
        return true;
    }

    override CursorType getCursorType(int x, int y)
    {
        return x < _box.x + _leftPaneWidth ? CursorType.arrow : CursorType.ibeam;
    }

    protected void updateMaxLineWidth()
    {
    }

    protected void processSmartIndent(EditOperation operation)
    {
        if (!supportsSmartIndents)
            return;
        if (!smartIndents && !smartIndentsAfterPaste)
            return;
        _content.syntaxSupport.applySmartIndent(operation, this);
    }

    protected void onContentChange(EditableContent content, EditOperation operation,
            ref TextRange rangeBefore, ref TextRange rangeAfter, Object source)
    {
        debug (editors)
            Log.d("onContentChange rangeBefore: ", rangeBefore, ", rangeAfter: ", rangeAfter,
                    ", text: ", operation.content);
        _contentChanged = true;
        if (source is this)
        {
            if (operation.action == EditAction.replaceContent)
            {
                // fully replaced, e.g., loaded from file or text property is assigned
                _caretPos = rangeAfter.end;
                _selectionRange.start = _caretPos;
                _selectionRange.end = _caretPos;
                updateMaxLineWidth();
                measureVisibleText();
                ensureCaretVisible();
                correctCaretPos();
                requestLayout();
                requestActionsUpdate();
            }
            else if (operation.action == EditAction.saveContent)
            {
                // saved
            }
            else
            {
                // modified
                _caretPos = rangeAfter.end;
                _selectionRange.start = _caretPos;
                _selectionRange.end = _caretPos;
                updateMaxLineWidth();
                measureVisibleText();
                ensureCaretVisible();
                requestActionsUpdate();
                processSmartIndent(operation);
            }
        }
        else
        {
            updateMaxLineWidth();
            measureVisibleText();
            correctCaretPos();
            requestLayout();
            requestActionsUpdate();
        }
        invalidate();
        if (modifiedStateChanged.assigned)
        {
            if (_lastReportedModifiedState != content.modified)
            {
                _lastReportedModifiedState = content.modified;
                modifiedStateChanged(this, content.modified);
                requestActionsUpdate();
            }
        }
        contentChanged(_content);
        handleEditorStateChange();
        return;
    }

    abstract protected Box textPosToClient(TextPosition p);

    abstract protected TextPosition clientToTextPos(Point pt);

    abstract protected void ensureCaretVisible(bool center = false);

    abstract protected Size measureVisibleText();

    protected
    {
        bool _lastReportedModifiedState;

        TextPosition _caretPos;
        TextRange _selectionRange;

        int _caretBlingingInterval = 800;
        ulong _caretTimerID;
        bool _caretBlinkingPhase;
        long _lastBlinkStartTs;
        bool _caretBlinks = true;

        dstring _minSizeTester;
        Size _measuredMinSize;
    }

    @property
    {
        /// Returns caret position
        TextPosition caretPos()
        {
            return _caretPos;
        }

        dstring minSizeTester()
        {
            return _minSizeTester;
        }

        EditWidgetBase minSizeTester(dstring txt)
        {
            _minSizeTester = txt;
            requestLayout();
            return this;
        }

        /// Current selection range
        TextRange selectionRange()
        {
            return _selectionRange;
        }
        /// ditto
        void selectionRange(TextRange range)
        {
            if (range.empty)
                return;
            _selectionRange = range;
            _caretPos = range.end;
            handleEditorStateChange();
        }

        /// When true, enables caret blinking, otherwise it's always visible
        bool showCaretBlinking()
        {
            return _caretBlinks;
        }
        /// ditto
        void showCaretBlinking(bool blinks)
        {
            _caretBlinks = blinks;
        }
    }

    //===============================================================
    // Caret

    /// Change caret position and ensure it is visible
    void setCaretPos(int line, int column, bool makeVisible = true, bool center = false)
    {
        _caretPos = TextPosition(line, column);
        correctCaretPos();
        invalidate();
        if (makeVisible)
            ensureCaretVisible(center);
        handleEditorStateChange();
    }

    protected void startCaretBlinking()
    {
        if (window)
        {
            static if (BACKEND_CONSOLE)
            {
                window.caretRect = caretRect;
                window.caretReplace = _replaceMode;
            }
            else
            {
                long ts = currentTimeMillis;
                if (_caretTimerID)
                {
                    if (_lastBlinkStartTs + _caretBlingingInterval / 4 > ts)
                        return; // don't update timer too frequently
                    cancelTimer(_caretTimerID);
                }
                _caretTimerID = setTimer(_caretBlingingInterval / 2);
                _lastBlinkStartTs = ts;
                _caretBlinkingPhase = false;
                invalidate();
            }
        }
    }

    protected void stopCaretBlinking()
    {
        if (window)
        {
            static if (BACKEND_CONSOLE)
            {
                window.caretRect = Rect.init;
            }
            else
            {
                if (_caretTimerID)
                {
                    cancelTimer(_caretTimerID);
                    _caretTimerID = 0;
                }
            }
        }
    }

    override bool onTimer(ulong id)
    {
        if (id == _caretTimerID)
        {
            _caretBlinkingPhase = !_caretBlinkingPhase;
            if (!_caretBlinkingPhase)
                _lastBlinkStartTs = currentTimeMillis;
            invalidate();
            //window.update(true);
            bool res = focused;
            if (!res)
                _caretTimerID = 0;
            return res;
        }
        if (id == _hoverTimer)
        {
            cancelHoverTimer();
            onHoverTimeout(_hoverMousePosition, _hoverTextPosition);
            return false;
        }
        return super.onTimer(id);
    }

    /// In word wrap mode, set by caretRect so ensureCaretVisible will know when to scroll
    protected int caretHeightOffset;

    /// Returns cursor rectangle
    protected Rect caretRect()
    {
        Rect caretRc = Rect(textPosToClient(_caretPos));
        if (_replaceMode)
        {
            dstring s = _content[_caretPos.line];
            if (_caretPos.pos < s.length)
            {
                TextPosition nextPos = _caretPos;
                nextPos.pos++;
                Rect nextRect = Rect(textPosToClient(nextPos));
                caretRc.right = nextRect.right;
            }
            else
            {
                caretRc.right += _spaceWidth;
            }
        }
        if (_wordWrap)
        {
            _scrollPos.x = 0;
            int wrapLine = findWrapLine(_caretPos);
            int xOffset;
            if (wrapLine > 0)
            {
                LineSpan curSpan = getSpan(_caretPos.line);
                xOffset = curSpan.accumulation(wrapLine, LineSpan.WrapPointInfo.width);
            }
            auto yOffset = -1 * _lineHeight * (wrapsUpTo(_caretPos.line) + wrapLine);
            caretHeightOffset = yOffset;
            caretRc.offset(clientBox.x - xOffset, clientBox.y - yOffset);
        }
        else
            caretRc.offset(clientBox.x, clientBox.y);
        return caretRc;
    }

    /// Draw caret
    protected void drawCaret(DrawBuf buf)
    {
        if (focused)
        {
            if (_caretBlinkingPhase && _caretBlinks)
            {
                return;
            }
            // draw caret
            Rect caretRc = caretRect();
            if (caretRc.intersects(Rect(clientBox)))
            {
                //caretRc.left++;
                if (_replaceMode && BACKEND_GUI)
                    buf.fillRect(caretRc, _caretColorReplace);
                //buf.drawLine(Point(caretRc.left, caretRc.bottom), Point(caretRc.left, caretRc.top), _caretColor);
                buf.fillRect(Rect(caretRc.left, caretRc.top, caretRc.left + 1, caretRc.bottom), _caretColor);
            }
        }
    }

    //===============================================================

    override void onThemeChanged()
    {
        super.onThemeChanged();
        _caretColor = currentTheme.getColor("edit_caret");
        _caretColorReplace = currentTheme.getColor("edit_caret_replace");
        _selectionColorFocused = currentTheme.getColor("editor_selection_focused");
        _selectionColorNormal = currentTheme.getColor("editor_selection_normal");
        _searchHighlightColorCurrent = currentTheme.getColor("editor_search_highlight_current");
        _searchHighlightColorOther = currentTheme.getColor("editor_search_highlight_other");
        _matchingBracketHightlightColor = currentTheme.getColor("editor_matching_bracket_highlight");
    }

    protected void updateFontProps()
    {
        FontRef font = font();
        _fixedFont = font.isFixed;
        _spaceWidth = font.spaceWidth;
        _lineHeight = font.height;
    }

    /// When cursor position or selection is out of content bounds, fix it to nearest valid position
    protected void correctCaretPos()
    {
        _content.correctPosition(_caretPos);
        _content.correctPosition(_selectionRange.start);
        _content.correctPosition(_selectionRange.end);
        if (_selectionRange.empty)
            _selectionRange = TextRange(_caretPos, _caretPos);
        handleEditorStateChange();
    }

    private int[] _lineWidthBuf;
    protected int calcLineWidth(dstring s)
    {
        int w = 0;
        if (_fixedFont)
        {
            int tabw = tabSize * _spaceWidth;
            // version optimized for fixed font
            for (int i = 0; i < s.length; i++)
            {
                if (s[i] == '\t')
                {
                    w += _spaceWidth;
                    w = (w + tabw - 1) / tabw * tabw;
                }
                else
                {
                    w += _spaceWidth;
                }
            }
        }
        else
        {
            // variable pitch font
            if (_lineWidthBuf.length < s.length)
                _lineWidthBuf.length = s.length;
            int charsMeasured = font.measureText(s, _lineWidthBuf, int.max);
            if (charsMeasured > 0)
                w = _lineWidthBuf[charsMeasured - 1];
        }
        return w;
    }

    protected void updateSelectionAfterCursorMovement(TextPosition oldCaretPos, bool selecting)
    {
        if (selecting)
        {
            if (oldCaretPos == _selectionRange.start)
            {
                if (_caretPos >= _selectionRange.end)
                {
                    _selectionRange.start = _selectionRange.end;
                    _selectionRange.end = _caretPos;
                }
                else
                {
                    _selectionRange.start = _caretPos;
                }
            }
            else if (oldCaretPos == _selectionRange.end)
            {
                if (_caretPos < _selectionRange.start)
                {
                    _selectionRange.end = _selectionRange.start;
                    _selectionRange.start = _caretPos;
                }
                else
                {
                    _selectionRange.end = _caretPos;
                }
            }
            else
            {
                if (oldCaretPos < _caretPos)
                {
                    // start selection forward
                    _selectionRange.start = oldCaretPos;
                    _selectionRange.end = _caretPos;
                }
                else
                {
                    // start selection backward
                    _selectionRange.start = _caretPos;
                    _selectionRange.end = oldCaretPos;
                }
            }
        }
        else
        {
            _selectionRange.start = _caretPos;
            _selectionRange.end = _caretPos;
        }
        invalidate();
        requestActionsUpdate();
        handleEditorStateChange();
    }

    protected dstring _textToHighlight;
    protected uint _textToHighlightOptions;

    /// Text pattern to highlight - e.g. for search
    @property dstring textToHighlight()
    {
        return _textToHighlight;
    }
    /// Set text to highlight -- e.g. for search
    void setTextToHighlight(dstring pattern, uint textToHighlightOptions)
    {
        _textToHighlight = pattern;
        _textToHighlightOptions = textToHighlightOptions;
        invalidate();
    }

    /// Used instead of using clientToTextPos for mouse input when in word wrap mode
    protected TextPosition wordWrapMouseOffset(int x, int y)
    {
        if (_span.length == 0)
            return clientToTextPos(Point(x, y));
        int selectedVisibleLine = y / _lineHeight;

        LineSpan _curSpan;

        int wrapLine = 0;
        int curLine = 0;
        bool foundWrap = false;
        int accumulativeWidths = 0;
        int curWrapOfSpan = 0;

        lineSpanIterate(delegate(LineSpan curSpan) {
            while (!foundWrap)
            {
                if (wrapLine == selectedVisibleLine)
                {
                    foundWrap = true;
                    break;
                }
                accumulativeWidths += curSpan.wrapPoints[curWrapOfSpan].wrapWidth;
                wrapLine++;
                curWrapOfSpan++;
                if (curWrapOfSpan >= curSpan.len)
                {
                    break;
                }
            }
            if (!foundWrap)
            {
                accumulativeWidths = 0;
                curLine++;
            }
            curWrapOfSpan = 0;
        });

        int fakeLineHeight = curLine * _lineHeight;
        return clientToTextPos(Point(x + accumulativeWidths, fakeLineHeight));
    }

    protected void selectWordByMouse(int x, int y)
    {
        TextPosition oldCaretPos = _caretPos;
        TextPosition newPos = _wordWrap ? wordWrapMouseOffset(x, y) : clientToTextPos(Point(x, y));
        TextRange r = content.wordBounds(newPos);
        if (r.start < r.end)
        {
            _selectionRange = r;
            _caretPos = r.end;
            invalidate();
            requestActionsUpdate();
        }
        else
        {
            _caretPos = newPos;
            updateSelectionAfterCursorMovement(oldCaretPos, false);
        }
        handleEditorStateChange();
    }

    protected void selectLineByMouse(int x, int y, bool onSameLineOnly = true)
    {
        TextPosition oldCaretPos = _caretPos;
        TextPosition newPos = _wordWrap ? wordWrapMouseOffset(x, y) : clientToTextPos(Point(x, y));
        if (onSameLineOnly && newPos.line != oldCaretPos.line)
            return; // different lines
        TextRange r = content.lineRange(newPos.line);
        if (r.start < r.end)
        {
            _selectionRange = r;
            _caretPos = r.end;
            invalidate();
            requestActionsUpdate();
        }
        else
        {
            _caretPos = newPos;
            updateSelectionAfterCursorMovement(oldCaretPos, false);
        }
        handleEditorStateChange();
    }

    protected void updateCaretPositionByMouse(int x, int y, bool selecting)
    {
        TextPosition oldCaretPos = _caretPos;
        TextPosition newPos = _wordWrap ? wordWrapMouseOffset(x, y) : clientToTextPos(Point(x, y));
        if (newPos != _caretPos)
        {
            _caretPos = newPos;
            updateSelectionAfterCursorMovement(oldCaretPos, selecting);
            invalidate();
        }
        handleEditorStateChange();
    }

    /// Generate string of spaces, to reach next tab position
    protected dstring spacesForTab(int currentPos)
    {
        int newPos = (currentPos + tabSize + 1) / tabSize * tabSize;
        return "                "d[0 .. (newPos - currentPos)];
    }

    /// Returns true if one or more lines selected fully
    protected bool multipleLinesSelected()
    {
        return _selectionRange.end.line > _selectionRange.start.line;
    }

    protected bool _camelCasePartsAsWords = true;

    void replaceSelectionText(dstring newText)
    {
        auto op = new EditOperation(EditAction.replace, _selectionRange, [newText]);
        _content.performOperation(op, this);
        ensureCaretVisible();
    }

    protected bool removeSelectionTextIfSelected()
    {
        if (_selectionRange.empty)
            return false;
        // clear selection
        auto op = new EditOperation(EditAction.replace, _selectionRange, [""d]);
        _content.performOperation(op, this);
        ensureCaretVisible();
        return true;
    }

    /// Returns current selection text (joined with LF when span over multiple lines)
    dstring getSelectedText()
    {
        return getRangeText(_selectionRange);
    }

    /// Returns text for specified range (joined with LF when span over multiple lines)
    dstring getRangeText(TextRange range)
    {
        dstring selectionText = concatDStrings(_content.rangeText(range));
        return selectionText;
    }

    /// Returns range for line with cursor
    @property public TextRange currentLineRange()
    {
        return _content.lineRange(_caretPos.line);
    }

    /// Clears selection (don't change text, just unselect)
    void clearSelection()
    {
        _selectionRange = TextRange(_caretPos, _caretPos);
        invalidate();
    }

    protected bool removeRangeText(TextRange range)
    {
        if (range.empty)
            return false;
        _selectionRange = range;
        _caretPos = _selectionRange.start;
        auto op = new EditOperation(EditAction.replace, range, [""d]);
        _content.performOperation(op, this);
        //_selectionRange.start = _caretPos;
        //_selectionRange.end = _caretPos;
        ensureCaretVisible();
        handleEditorStateChange();
        return true;
    }

    //===============================================================
    // Actions
/+
    override bool isActionEnabled(const OldAction action)
    {
        switch (action.id) with (EditorActions)
        {
        case Indent:
        case Unindent:
            return enabled;
        case Copy:
            return _copyCurrentLineWhenNoSelection || !_selectionRange.empty;
        case Cut:
            return enabled && (_copyCurrentLineWhenNoSelection || !_selectionRange.empty);
        case Paste:
            return enabled && platform.hasClipboardText();
        case Undo:
            return enabled && _content.hasUndo;
        case Redo:
            return enabled && _content.hasRedo;
        case ToggleBookmark:
            return _content.multiline;
        case GoToNextBookmark:
            return _content.multiline && _content.lineIcons.hasBookmarks;
        case GoToPreviousBookmark:
            return _content.multiline && _content.lineIcons.hasBookmarks;

        case Replace:
            return _content.multiline && !readOnly;
        case Find:
        case FindNext:
        case FindPrev:
            return _content.multiline;
        default:
            return super.isActionEnabled(action);
        }
    }

    override bool handleActionStateRequest(const OldAction a)
    {
        switch (a.id) with (EditorActions)
        {
        case ToggleBlockComment:
            if (!_content.syntaxSupport || !_content.syntaxSupport.supportsToggleBlockComment)
                a.state = ACTION_STATE_INVISIBLE;
            else if (enabled && _content.syntaxSupport.canToggleBlockComment(_selectionRange))
                a.state = ACTION_STATE_ENABLED;
            else
                a.state = ACTION_STATE_DISABLE;
            return true;
        case ToggleLineComment:
            if (!_content.syntaxSupport || !_content.syntaxSupport.supportsToggleLineComment)
                a.state = ACTION_STATE_INVISIBLE;
            else if (enabled && _content.syntaxSupport.canToggleLineComment(_selectionRange))
                a.state = ACTION_STATE_ENABLED;
            else
                a.state = ACTION_STATE_DISABLE;
            return true;
        case Copy:
        case Cut:
        case Paste:
        case Undo:
        case Redo:
        case Indent:
        case Unindent:
            if (isActionEnabled(a))
                a.state = ACTION_STATE_ENABLED;
            else
                a.state = ACTION_STATE_DISABLE;
            return true;
        default:
            return super.handleActionStateRequest(a);
        }
    }
+/

    protected void bindActions()
    {
        debug (editors)
            Log.d("Editor `", id, "`: bind actions");

        ACTION_LINE_BEGIN.bind(this, { LineBegin(false); });
        ACTION_LINE_END.bind(this, { LineEnd(false); });
        ACTION_DOCUMENT_BEGIN.bind(this, { DocumentBegin(false); });
        ACTION_DOCUMENT_END.bind(this, { DocumentEnd(false); });
        ACTION_SELECT_LINE_BEGIN.bind(this, { LineBegin(true); });
        ACTION_SELECT_LINE_END.bind(this, { LineEnd(true); });
        ACTION_SELECT_DOCUMENT_BEGIN.bind(this, { DocumentBegin(true); });
        ACTION_SELECT_DOCUMENT_END.bind(this, { DocumentEnd(true); });

        ACTION_BACKSPACE.bind(this, &DelPrevChar);
        ACTION_DELETE.bind(this, &DelNextChar);
        ACTION_ED_DEL_PREV_WORD.bind(this, &DelPrevWord);
        ACTION_ED_DEL_NEXT_WORD.bind(this, &DelNextWord);

        ACTION_ED_INDENT.bind(this, &Tab);
        ACTION_ED_UNINDENT.bind(this, &BackTab);

        ACTION_SELECT_ALL.bind(this, &selectAll);

        ACTION_UNDO.bind(this, { _content.undo(this); });
        ACTION_REDO.bind(this, { _content.redo(this); });

        ACTION_CUT.bind(this, &cut);
        ACTION_COPY.bind(this, &copy);
        ACTION_PASTE.bind(this, &paste);

        ACTION_ED_TOGGLE_REPLACE_MODE.bind(this, {
            replaceMode = !replaceMode;
            invalidate();
        });
    }

    protected void unbindActions()
    {
        bunch(
            ACTION_LINE_BEGIN,
            ACTION_LINE_END,
            ACTION_DOCUMENT_BEGIN,
            ACTION_DOCUMENT_END,
            ACTION_SELECT_LINE_BEGIN,
            ACTION_SELECT_LINE_END,
            ACTION_SELECT_DOCUMENT_BEGIN,
            ACTION_SELECT_DOCUMENT_END,
            ACTION_BACKSPACE,
            ACTION_DELETE,
            ACTION_ED_DEL_PREV_WORD,
            ACTION_ED_DEL_NEXT_WORD,
            ACTION_ED_INDENT,
            ACTION_ED_UNINDENT,
            ACTION_SELECT_ALL,
            ACTION_UNDO,
            ACTION_REDO,
            ACTION_CUT,
            ACTION_COPY,
            ACTION_PASTE,
            ACTION_ED_TOGGLE_REPLACE_MODE
        ).unbind(this);
    }

    protected void LineBegin(bool select)
    {
        TextPosition oldCaretPos = _caretPos;
        auto space = _content.getLineWhiteSpace(_caretPos.line);
        if (_caretPos.pos > 0)
        {
            if (_caretPos.pos > space.firstNonSpaceIndex && space.firstNonSpaceIndex > 0)
                _caretPos.pos = space.firstNonSpaceIndex;
            else
                _caretPos.pos = 0;
            ensureCaretVisible();
            updateSelectionAfterCursorMovement(oldCaretPos, select);
        }
        else
        {
            // caret pos is 0
            if (space.firstNonSpaceIndex > 0)
                _caretPos.pos = space.firstNonSpaceIndex;
            ensureCaretVisible();
            updateSelectionAfterCursorMovement(oldCaretPos, select);
            if (!select && _caretPos == oldCaretPos)
            {
                clearSelection();
            }
        }
    }
    protected void LineEnd(bool select)
    {
        TextPosition oldCaretPos = _caretPos;
        dstring currentLine = _content[_caretPos.line];
        if (_caretPos.pos < currentLine.length)
        {
            _caretPos.pos = cast(int)currentLine.length;
            ensureCaretVisible();
            updateSelectionAfterCursorMovement(oldCaretPos, select);
        }
        else if (!select)
        {
            clearSelection();
        }
    }
    protected void DocumentBegin(bool select)
    {
        TextPosition oldCaretPos = _caretPos;
        if (_caretPos.pos > 0 || _caretPos.line > 0)
        {
            _caretPos.line = 0;
            _caretPos.pos = 0;
            ensureCaretVisible();
            updateSelectionAfterCursorMovement(oldCaretPos, select);
        }
    }
    protected void DocumentEnd(bool select)
    {
        TextPosition oldCaretPos = _caretPos;
        if (_caretPos.line < _content.length - 1 || _caretPos.pos < _content[_content.length - 1].length)
        {
            _caretPos.line = _content.length - 1;
            _caretPos.pos = cast(int)_content[_content.length - 1].length;
            ensureCaretVisible();
            updateSelectionAfterCursorMovement(oldCaretPos, select);
        }
    }

    protected void DelPrevChar()
    {
        if (readOnly)
            return;
        correctCaretPos();
        if (removeSelectionTextIfSelected()) // clear selection
            return;
        if (_caretPos.pos > 0)
        {
            // delete prev char in current line
            TextRange range = TextRange(_caretPos, _caretPos);
            range.start.pos--;
            removeRangeText(range);
        }
        else if (_caretPos.line > 0)
        {
            // merge with previous line
            TextRange range = TextRange(_caretPos, _caretPos);
            range.start = _content.lineEnd(range.start.line - 1);
            removeRangeText(range);
        }
    }
    protected void DelNextChar()
    {
        dstring currentLine = _content[_caretPos.line];
        if (readOnly)
            return;
        correctCaretPos();
        if (removeSelectionTextIfSelected()) // clear selection
            return;
        if (_caretPos.pos < currentLine.length)
        {
            // delete char in current line
            TextRange range = TextRange(_caretPos, _caretPos);
            range.end.pos++;
            removeRangeText(range);
        }
        else if (_caretPos.line < _content.length - 1)
        {
            // merge with next line
            TextRange range = TextRange(_caretPos, _caretPos);
            range.end.line++;
            range.end.pos = 0;
            removeRangeText(range);
        }
    }
    protected void DelPrevWord()
    {
        if (readOnly)
            return;
        correctCaretPos();
        if (removeSelectionTextIfSelected()) // clear selection
            return;
        TextPosition newpos = _content.moveByWord(_caretPos, -1, _camelCasePartsAsWords);
        if (newpos < _caretPos)
            removeRangeText(TextRange(newpos, _caretPos));
    }
    protected void DelNextWord()
    {
        if (readOnly)
            return;
        correctCaretPos();
        if (removeSelectionTextIfSelected()) // clear selection
            return;
        TextPosition newpos = _content.moveByWord(_caretPos, 1, _camelCasePartsAsWords);
        if (newpos > _caretPos)
            removeRangeText(TextRange(_caretPos, newpos));
    }

    protected void Tab()
    {
        if (readOnly)
            return;
        if (_selectionRange.empty)
        {
            if (useSpacesForTabs)
            {
                // insert one or more spaces to
                auto op = new EditOperation(EditAction.replace,
                        TextRange(_caretPos, _caretPos), [spacesForTab(_caretPos.pos)]);
                _content.performOperation(op, this);
            }
            else
            {
                // just insert tab character
                auto op = new EditOperation(EditAction.replace,
                        TextRange(_caretPos, _caretPos), ["\t"d]);
                _content.performOperation(op, this);
            }
        }
        else
        {
            if (multipleLinesSelected())
            {
                indentRange(false);
            }
            else
            {
                // insert tab
                if (useSpacesForTabs)
                {
                    // insert one or more spaces to
                    auto op = new EditOperation(EditAction.replace,
                            _selectionRange, [spacesForTab(_selectionRange.start.pos)]);
                    _content.performOperation(op, this);
                }
                else
                {
                    // just insert tab character
                    auto op = new EditOperation(EditAction.replace, _selectionRange, ["\t"d]);
                    _content.performOperation(op, this);
                }
            }

        }
    }
    protected void BackTab()
    {
        if (readOnly)
            return;
        if (_selectionRange.empty)
        {
            // remove spaces before caret
            TextRange r = spaceBefore(_caretPos);
            if (!r.empty)
            {
                auto op = new EditOperation(EditAction.replace, r, [""d]);
                _content.performOperation(op, this);
            }
        }
        else
        {
            if (multipleLinesSelected())
            {
                indentRange(true);
            }
            else
            {
                // remove space before selection
                TextRange r = spaceBefore(_selectionRange.start);
                if (!r.empty)
                {
                    int nchars = r.end.pos - r.start.pos;
                    TextRange saveRange = _selectionRange;
                    TextPosition saveCursor = _caretPos;
                    auto op = new EditOperation(EditAction.replace, r, [""d]);
                    _content.performOperation(op, this);
                    if (saveCursor.line == saveRange.start.line)
                        saveCursor.pos -= nchars;
                    if (saveRange.end.line == saveRange.start.line)
                        saveRange.end.pos -= nchars;
                    saveRange.start.pos -= nchars;
                    _selectionRange = saveRange;
                    _caretPos = saveCursor;
                    ensureCaretVisible();
                }
            }
        }
    }

    /// Cut currently selected text into clipboard
    void cut()
    {
        if (readOnly)
            return;
        TextRange range = _selectionRange;
        if (range.empty && _copyCurrentLineWhenNoSelection)
        {
            range = currentLineRange;
        }
        if (!range.empty)
        {
            dstring selectionText = getRangeText(range);
            platform.setClipboardText(selectionText);
            auto op = new EditOperation(EditAction.replace, range, [""d]);
            _content.performOperation(op, this);
        }
    }

    /// Copy currently selected text into clipboard
    void copy()
    {
        TextRange range = _selectionRange;
        if (range.empty && _copyCurrentLineWhenNoSelection)
        {
            range = currentLineRange;
        }
        if (!range.empty)
        {
            dstring selectionText = getRangeText(range);
            platform.setClipboardText(selectionText);
        }
    }

    /// Replace currently selected text with clipboard content
    void paste()
    {
        if (readOnly)
            return;
        dstring selectionText = platform.getClipboardText();
        dstring[] lines;
        if (_content.multiline)
        {
            lines = splitDString(selectionText);
        }
        else
        {
            lines = [replaceEOLsWithSpaces(selectionText)];
        }
        auto op = new EditOperation(EditAction.replace, _selectionRange, lines);
        _content.performOperation(op, this);
    }

    /// Select whole text
    void selectAll()
    {
        _selectionRange.start.line = 0;
        _selectionRange.start.pos = 0;
        _selectionRange.end = _content.lineEnd(_content.length - 1);
        _caretPos = _selectionRange.end;
        ensureCaretVisible();
        invalidate();
    }

    protected TextRange spaceBefore(TextPosition pos)
    {
        TextRange res = TextRange(pos, pos);
        dstring s = _content[pos.line];
        int x = 0;
        int start = -1;
        for (int i = 0; i < pos.pos; i++)
        {
            dchar ch = s[i];
            if (ch == ' ')
            {
                if (start == -1 || (x % tabSize) == 0)
                    start = i;
                x++;
            }
            else if (ch == '\t')
            {
                if (start == -1 || (x % tabSize) == 0)
                    start = i;
                x = (x + tabSize + 1) / tabSize * tabSize;
            }
            else
            {
                x++;
                start = -1;
            }
        }
        if (start != -1)
        {
            res.start.pos = start;
        }
        return res;
    }

    /// Change line indent
    protected dstring indentLine(dstring src, bool back, TextPosition* cursorPos)
    {
        int firstNonSpace = -1;
        int x = 0;
        int unindentPos = -1;
        int cursor = cursorPos ? cursorPos.pos : 0;
        for (int i = 0; i < src.length; i++)
        {
            dchar ch = src[i];
            if (ch == ' ')
            {
                x++;
            }
            else if (ch == '\t')
            {
                x = (x + tabSize + 1) / tabSize * tabSize;
            }
            else
            {
                firstNonSpace = i;
                break;
            }
            if (x <= tabSize)
                unindentPos = i + 1;
        }
        if (firstNonSpace == -1) // only spaces or empty line -- do not change it
            return src;
        if (back)
        {
            // unindent
            if (unindentPos == -1)
                return src; // no change
            if (unindentPos == src.length)
            {
                if (cursorPos)
                    cursorPos.pos = 0;
                return ""d;
            }
            if (cursor >= unindentPos)
                cursorPos.pos -= unindentPos;
            return src[unindentPos .. $].dup;
        }
        else
        {
            // indent
            if (useSpacesForTabs)
            {
                if (cursor > 0)
                    cursorPos.pos += tabSize;
                return spacesForTab(0) ~ src;
            }
            else
            {
                if (cursor > 0)
                    cursorPos.pos++;
                return "\t"d ~ src;
            }
        }
    }

    /// Indent / unindent range
    protected void indentRange(bool back)
    {
        TextRange r = _selectionRange;
        r.start.pos = 0;
        if (r.end.pos > 0)
            r.end = _content.lineBegin(r.end.line + 1);
        if (r.end.line <= r.start.line)
            r = TextRange(_content.lineBegin(_caretPos.line), _content.lineBegin(_caretPos.line + 1));
        int lineCount = r.end.line - r.start.line;
        if (r.end.pos > 0)
            lineCount++;
        dstring[] newContent = new dstring[lineCount + 1];
        bool changed = false;
        for (int i = 0; i < lineCount; i++)
        {
            dstring srcline = _content.line(r.start.line + i);
            dstring dstline = indentLine(srcline, back, r.start.line + i == _caretPos.line ? &_caretPos : null);
            newContent[i] = dstline;
            if (dstline.length != srcline.length)
                changed = true;
        }
        if (changed)
        {
            TextRange saveRange = r;
            TextPosition saveCursor = _caretPos;
            auto op = new EditOperation(EditAction.replace, r, newContent);
            _content.performOperation(op, this);
            _selectionRange = saveRange;
            _caretPos = saveCursor;
            ensureCaretVisible();
        }
    }
/+
    override protected OldAction findActionByKey(uint keyCode, uint flags)
    {
        // don't handle tabs when disabled
        if (keyCode == KeyCode.tab && (flags == 0 || flags == KeyFlag.shift) && (!_wantTabs || readOnly))
            return null;
        return super.findActionByKey(keyCode, flags);
    }+/

    //===============================================================
    // Events

    override bool onKeyEvent(KeyEvent event)
    {
        import std.ascii : isAlpha;

        debug (editors)
            Log.d("onKeyEvent ", event.action, " ", event.keyCode, " flags ", event.flags);
        if (focused)
            startCaretBlinking();
        cancelHoverTimer();

        bool noOtherModifiers = !(event.flags & (KeyFlag.alt | KeyFlag.menu));
        if (event.action == KeyAction.keyDown && noOtherModifiers)
        {
            TextPosition oldCaretPos = _caretPos;
            dstring currentLine = _content[_caretPos.line];

            bool shiftPressed = !!(event.flags & KeyFlag.shift);
            bool controlPressed = !!(event.flags & KeyFlag.control);
            if (event.keyCode == KeyCode.left)
            {
                if (!controlPressed)
                {
                    // move cursor one char left (with selection when Shift pressed)
                    correctCaretPos();
                    if (_caretPos.pos > 0)
                    {
                        _caretPos.pos--;
                        updateSelectionAfterCursorMovement(oldCaretPos, shiftPressed);
                        ensureCaretVisible();
                    }
                    else if (_caretPos.line > 0)
                    {
                        _caretPos = _content.lineEnd(_caretPos.line - 1);
                        updateSelectionAfterCursorMovement(oldCaretPos, shiftPressed);
                        ensureCaretVisible();
                    }
                    return true;
                }
                else
                {
                    // move cursor one word left (with selection when Shift pressed)
                    TextPosition newpos = _content.moveByWord(_caretPos, -1, _camelCasePartsAsWords);
                    if (newpos != _caretPos)
                    {
                        _caretPos = newpos;
                        updateSelectionAfterCursorMovement(oldCaretPos, shiftPressed);
                        ensureCaretVisible();
                    }
                    return true;
                }
            }
            if (event.keyCode == KeyCode.right)
            {
                if (!controlPressed)
                {
                    // move cursor one char right (with selection when Shift pressed)
                    correctCaretPos();
                    if (_caretPos.pos < currentLine.length)
                    {
                        _caretPos.pos++;
                        updateSelectionAfterCursorMovement(oldCaretPos, shiftPressed);
                        ensureCaretVisible();
                    }
                    else if (_caretPos.line < _content.length - 1 && _content.multiline)
                    {
                        _caretPos.pos = 0;
                        _caretPos.line++;
                        updateSelectionAfterCursorMovement(oldCaretPos, shiftPressed);
                        ensureCaretVisible();
                    }
                    return true;
                }
                else
                {
                    // move cursor one word right (with selection when Shift pressed)
                    TextPosition newpos = _content.moveByWord(_caretPos, 1, _camelCasePartsAsWords);
                    if (newpos != _caretPos)
                    {
                        _caretPos = newpos;
                        updateSelectionAfterCursorMovement(oldCaretPos, shiftPressed);
                        ensureCaretVisible();
                    }
                    return true;
                }
            }
        }

        bool ctrlOrAltPressed = !!(event.flags & KeyFlag.control); // FIXME: Alt needed?
        if (event.action == KeyAction.text && event.text.length && !ctrlOrAltPressed)
        {
            debug (editors)
                Log.d("text entered: ", event.text);
            if (readOnly)
                return true;
            if (!(!!(event.flags & KeyFlag.alt) && event.text.length == 1 && isAlpha(event.text[0])))
            { // filter out Alt+A..Z
                if (replaceMode && _selectionRange.empty &&
                        _content[_caretPos.line].length >= _caretPos.pos + event.text.length)
                {
                    // replace next char(s)
                    TextRange range = _selectionRange;
                    range.end.pos += cast(int)event.text.length;
                    auto op = new EditOperation(EditAction.replace, range, [event.text]);
                    _content.performOperation(op, this);
                }
                else
                {
                    auto op = new EditOperation(EditAction.replace, _selectionRange, [event.text]);
                    _content.performOperation(op, this);
                }
                return true;
            }
        }
        return super.onKeyEvent(event);
    }

    protected TextPosition _hoverTextPosition;
    protected Point _hoverMousePosition;
    protected ulong _hoverTimer;
    protected long _hoverTimeoutMillis = 800;

    /// Override to handle mouse hover timeout in text
    protected void onHoverTimeout(Point pt, TextPosition pos)
    {
        // override to do something useful on hover timeout
    }

    protected void onHover(Point pos)
    {
        if (_hoverMousePosition == pos)
            return;
        debug (editors)
            Log.d("onHover ", pos);
        int x = pos.x - box.x - _leftPaneWidth;
        int y = pos.y - box.y;
        _hoverMousePosition = pos;
        _hoverTextPosition = clientToTextPos(Point(x, y));
        cancelHoverTimer();
        Box reversePos = textPosToClient(_hoverTextPosition);
        if (x < reversePos.x + 10.pt)
            _hoverTimer = setTimer(_hoverTimeoutMillis);
    }

    protected void cancelHoverTimer()
    {
        if (_hoverTimer)
        {
            cancelTimer(_hoverTimer);
            _hoverTimer = 0;
        }
    }

    override bool onMouseEvent(MouseEvent event)
    {
        debug (editors)
            Log.d("onMouseEvent ", id, " ", event.action, "  (", event.x, ",", event.y, ")");
        // support onClick
        bool insideLeftPane = event.x < clientBox.x && event.x >= clientBox.x - _leftPaneWidth;
        if (event.action == MouseAction.buttonDown && insideLeftPane)
        {
            setFocus();
            cancelHoverTimer();
            if (onLeftPaneMouseClick(event))
                return true;
        }
        if (event.action == MouseAction.buttonDown && event.button == MouseButton.left)
        {
            setFocus();
            cancelHoverTimer();
            if (event.tripleClick)
            {
                selectLineByMouse(event.x - clientBox.x, event.y - clientBox.y);
            }
            else if (event.doubleClick)
            {
                selectWordByMouse(event.x - clientBox.x, event.y - clientBox.y);
            }
            else
            {
                auto doSelect = cast(bool)(event.keyFlags & MouseFlag.shift);
                updateCaretPositionByMouse(event.x - clientBox.x, event.y - clientBox.y, doSelect);

                if (event.keyFlags == MouseFlag.control)
                    onControlClick();
            }
            startCaretBlinking();
            invalidate();
            return true;
        }
        if (event.action == MouseAction.move && (event.flags & MouseButton.left) != 0)
        {
            updateCaretPositionByMouse(event.x - clientBox.x, event.y - clientBox.y, true);
            return true;
        }
        if (event.action == MouseAction.move && event.flags == 0)
        {
            // hover
            if (focused && !insideLeftPane)
            {
                onHover(event.pos);
            }
            else
            {
                cancelHoverTimer();
            }
            return true;
        }
        if (event.action == MouseAction.buttonUp && event.button == MouseButton.left)
        {
            cancelHoverTimer();
            return true;
        }
        if (event.action == MouseAction.focusOut || event.action == MouseAction.cancel)
        {
            cancelHoverTimer();
            return true;
        }
        if (event.action == MouseAction.focusIn)
        {
            cancelHoverTimer();
            return true;
        }
        cancelHoverTimer();
        return super.onMouseEvent(event);
    }

    /// Handle Ctrl + Left mouse click on text
    protected void onControlClick()
    {
        // override to do something useful on Ctrl + Left mouse click in text
    }
}

/// Single line editor
class EditLine : EditWidgetBase
{
    @property
    {
        /// Password character - 0 for normal editor, some character
        /// e.g. '*' to hide text by replacing all characters with this char
        dchar passwordChar()
        {
            return _passwordChar;
        }
        /// ditto
        EditLine passwordChar(dchar ch)
        {
            if (_passwordChar != ch)
            {
                _passwordChar = ch;
                requestLayout();
            }
            return this;
        }
    }

    /// Handle Enter key press inside line editor
    Signal!(bool delegate(EditWidgetBase)) enterKeyPressed; // FIXME: better name

    protected
    {
        dstring _measuredText;
        int[] _measuredTextWidths;
        Size _measuredTextSize;

        dchar _passwordChar = 0;
    }

    this(dstring initialContent = null)
    {
        super(ScrollBarMode.invisible, ScrollBarMode.invisible);
        _content = new EditableContent(false);
        _content.contentChanged = &onContentChange;
        _selectAllWhenFocusedWithTab = true;
        _deselectAllWhenUnfocused = true;
        wantTabs = false;
        text = initialContent;
        _minSizeTester = "aaaaa"d;
        onThemeChanged();
    }

    /// Set default popup menu with copy/paste/cut/undo/redo
    EditLine setDefaultPopupMenu()
    {
        popupMenu = new Menu;
        popupMenu.add(ACTION_UNDO, ACTION_REDO, ACTION_CUT, ACTION_COPY, ACTION_PASTE);
        return this;
    }

    override protected Box textPosToClient(TextPosition p)
    {
        Box res;
        res.h = clientBox.height;
        if (p.pos == 0)
            res.x = 0;
        else if (p.pos >= _measuredText.length)
            res.x = _measuredTextSize.w;
        else
            res.x = _measuredTextWidths[p.pos - 1];
        res.x -= _scrollPos.x;
        res.w = 1;
        return res;
    }

    override protected TextPosition clientToTextPos(Point pt)
    {
        pt.x += _scrollPos.x;
        TextPosition res;
        for (int i = 0; i < _measuredText.length; i++)
        {
            int x0 = i > 0 ? _measuredTextWidths[i - 1] : 0;
            int x1 = _measuredTextWidths[i];
            int mx = (x0 + x1) >> 1;
            if (pt.x <= mx)
            {
                res.pos = i;
                return res;
            }
        }
        res.pos = cast(int)_measuredText.length;
        return res;
    }

    override protected void ensureCaretVisible(bool center = false)
    {
        //_scrollPos
        Box b = textPosToClient(_caretPos);
        if (b.x < 0)
        {
            // scroll left
            _scrollPos.x -= -b.x + clientBox.width / 10;
            _scrollPos.x = max(_scrollPos.x, 0);
            invalidate();
        }
        else if (b.x >= clientBox.width - 10)
        {
            // scroll right
            _scrollPos.x += (b.x - clientBox.width) + _spaceWidth * 4;
            invalidate();
        }
        updateScrollBars();
        handleEditorStateChange();
    }

    protected dstring applyPasswordChar(dstring s)
    {
        if (!_passwordChar || s.length == 0)
            return s;
        dchar[] ss = s.dup;
        foreach (ref ch; ss)
            ch = _passwordChar;
        return cast(dstring)ss;
    }

    override bool onKeyEvent(KeyEvent event)
    {
        if (enterKeyPressed.assigned)
        {
            if (event.keyCode == KeyCode.enter && event.modifiers == 0)
            {
                if (event.action == KeyAction.keyDown)
                    return true;
                if (event.action == KeyAction.keyUp)
                {
                    if (enterKeyPressed(this))
                        return true;
                }
            }
        }
        return super.onKeyEvent(event);
    }

    override bool onMouseEvent(MouseEvent event)
    {
        return super.onMouseEvent(event);
    }

    override Size computeMinSize() // TODO: compute once when changed
    {
        FontRef f = font();
        _measuredMinSize = f.textSize(_minSizeTester, MAX_WIDTH_UNSPECIFIED, tabSize);
        return Size(_measuredMinSize.w + _leftPaneWidth, _measuredMinSize.h);
    }

    override Boundaries computeBoundaries()
    {
        updateFontProps();
        measureVisibleText();
        return super.computeBoundaries();
    }

    override protected Size measureVisibleText()
    {
        FontRef font = font();
        //Size sz = font.textSize(text);
        _measuredText = applyPasswordChar(text);
        _measuredTextWidths.length = _measuredText.length;
        int charsMeasured = font.measureText(_measuredText, _measuredTextWidths, MAX_WIDTH_UNSPECIFIED, tabSize);
        _measuredTextSize.w = charsMeasured > 0 ? _measuredTextWidths[charsMeasured - 1] : 0;
        _measuredTextSize.h = font.height;
        return _measuredTextSize;
    }

    override void layout(Box geom)
    {
        _needLayout = false;
        if (visibility == Visibility.gone)
            return;

//         Size sz = Size(rc.width, computedHeight);
//         applyAlign(rc, sz);
        _box = geom;

        applyMargins(geom);
        applyPadding(geom);
        _clientBox = geom;

        if (_contentChanged)
        {
            measureVisibleText();
            _contentChanged = false;
        }
    }

    /// Override to custom highlight of line background
    protected void drawLineBackground(DrawBuf buf, Rect lineRect, Rect visibleRect)
    {
        if (!_selectionRange.empty)
        {
            // line inside selection
            int start = textPosToClient(_selectionRange.start).x;
            int end = textPosToClient(_selectionRange.end).x;
            Rect rc = lineRect;
            rc.left = start + clientBox.x;
            rc.right = end + clientBox.x;
            if (!rc.empty)
            {
                // draw selection rect for line
                buf.fillRect(rc, focused ? _selectionColorFocused : _selectionColorNormal);
            }
            if (_leftPaneWidth > 0)
            {
                Rect leftPaneRect = visibleRect;
                leftPaneRect.right = leftPaneRect.left;
                leftPaneRect.left -= _leftPaneWidth;
                drawLeftPane(buf, leftPaneRect, 0);
            }
        }
    }

    override void onDraw(DrawBuf buf)
    {
        if (visibility != Visibility.visible)
            return;

        super.onDraw(buf);
        Box b = _box;
        applyMargins(b);
        applyPadding(b);
        auto saver = ClipRectSaver(buf, b, alpha);

        FontRef font = font();
        dstring txt = applyPasswordChar(text);

        drawLineBackground(buf, Rect(clientBox), Rect(clientBox));
        font.drawText(buf, b.x - _scrollPos.x, b.y, txt, textColor, tabSize);

        drawCaret(buf);
    }
}

/// Multiline editor
class EditBox : EditWidgetBase
{
    @property
    {
        override int fontSize() const
        {
            return super.fontSize();
        }

        override Widget fontSize(int size)
        {
            // Need to rewrap if fontSize changed
            _needRewrap = true;
            return super.fontSize(size);
        }

        int minFontSize()
        {
            return _minFontSize;
        }

        EditBox minFontSize(int size)
        {
            _minFontSize = size;
            return this;
        }

        int maxFontSize()
        {
            return _maxFontSize;
        }

        EditBox maxFontSize(int size)
        {
            _maxFontSize = size;
            return this;
        }

        /// When true, show marks for tabs and spaces at beginning and end of line, and tabs inside line
        bool showWhiteSpaceMarks() const
        {
            return _showWhiteSpaceMarks;
        }
        /// ditto
        EditBox showWhiteSpaceMarks(bool show)
        {
            if (_showWhiteSpaceMarks != show)
            {
                _showWhiteSpaceMarks = show;
                invalidate();
            }
            return this;
        }
    }

    protected
    {
        int _firstVisibleLine;

        int _maxLineWidth;
        int _numVisibleLines; // number of lines visible in client area
        dstring[] _visibleLines; // text for visible lines
        int[][] _visibleLinesMeasurement; // char positions for visible lines
        int[] _visibleLinesWidths; // width (in pixels) of visible lines
        CustomCharProps[][] _visibleLinesHighlights;
        CustomCharProps[][] _visibleLinesHighlightsBuf;

        bool _showWhiteSpaceMarks;
    }

    this(dstring initialContent = null,
         ScrollBarMode hscrollbarMode = ScrollBarMode.automatic,
         ScrollBarMode vscrollbarMode = ScrollBarMode.automatic)
    {
        super(hscrollbarMode, vscrollbarMode);
        _content = new EditableContent(true); // multiline
        _content.contentChanged = &onContentChange;
        text = initialContent;
        _minSizeTester = "aaaaa\naaaaa"d;
        onThemeChanged();
    }

    ~this()
    {
        eliminate(_findPanel);
    }

    override protected void bindActions()
    {
        super.bindActions();

        ACTION_PAGE_UP.bind(this, { PageUp(false); });
        ACTION_PAGE_DOWN.bind(this, { PageDown(false); });
        ACTION_PAGE_BEGIN.bind(this, { PageBegin(false); });
        ACTION_PAGE_END.bind(this, { PageEnd(false); });
        ACTION_SELECT_PAGE_UP.bind(this, { PageUp(true); });
        ACTION_SELECT_PAGE_DOWN.bind(this, { PageDown(true); });
        ACTION_SELECT_PAGE_BEGIN.bind(this, { PageBegin(true); });
        ACTION_SELECT_PAGE_END.bind(this, { PageEnd(true); });

        ACTION_ZOOM_IN.bind(this, { zoom(true); });
        ACTION_ZOOM_OUT.bind(this, { zoom(false); });

        ACTION_ENTER.bind(this, &InsertNewLine);
        ACTION_ED_PREPEND_NEW_LINE.bind(this, &PrependNewLine);
        ACTION_ED_APPEND_NEW_LINE.bind(this, &AppendNewLine);
        ACTION_ED_DELETE_LINE.bind(this, &DeleteLine);

        ACTION_ED_TOGGLE_BOOKMARK.bind(this, {
            _content.lineIcons.toggleBookmark(_caretPos.line);
        });
        ACTION_ED_GOTO_NEXT_BOOKMARK.bind(this, {
            LineIcon mark = _content.lineIcons.findNext(LineIconType.bookmark,
                    _selectionRange.end.line, 1);
            if (mark)
                setCaretPos(mark.line, 0, true);
        });
        ACTION_ED_GOTO_PREVIOUS_BOOKMARK.bind(this, {
            LineIcon mark = _content.lineIcons.findNext(LineIconType.bookmark,
                    _selectionRange.end.line, -1);
            if (mark)
                setCaretPos(mark.line, 0, true);
        });

        ACTION_ED_TOGGLE_LINE_COMMENT.bind(this, &ToggleLineComment);
        ACTION_ED_TOGGLE_BLOCK_COMMENT.bind(this, &ToggleBlockComment);

        ACTION_ED_FIND.bind(this, &openFindPanel);
        ACTION_ED_FIND_NEXT.bind(this, { findNext(false); });
        ACTION_ED_FIND_PREV.bind(this, { findNext(true); });
        ACTION_ED_REPLACE.bind(this, &openReplacePanel);
    }

    override protected void unbindActions()
    {
        super.unbindActions();

        bunch(
            ACTION_PAGE_UP,
            ACTION_PAGE_DOWN,
            ACTION_PAGE_BEGIN,
            ACTION_PAGE_END,
            ACTION_SELECT_PAGE_UP,
            ACTION_SELECT_PAGE_DOWN,
            ACTION_SELECT_PAGE_BEGIN,
            ACTION_SELECT_PAGE_END,
            ACTION_ZOOM_IN,
            ACTION_ZOOM_OUT,
            ACTION_ENTER,
            ACTION_ED_TOGGLE_BOOKMARK,
            ACTION_ED_GOTO_NEXT_BOOKMARK,
            ACTION_ED_GOTO_PREVIOUS_BOOKMARK,
            ACTION_ED_TOGGLE_LINE_COMMENT,
            ACTION_ED_TOGGLE_BLOCK_COMMENT,
            ACTION_ED_PREPEND_NEW_LINE,
            ACTION_ED_APPEND_NEW_LINE,
            ACTION_ED_DELETE_LINE,
            ACTION_ED_FIND,
            ACTION_ED_FIND_NEXT,
            ACTION_ED_FIND_PREV,
            ACTION_ED_REPLACE
        ).unbind(this);
    }

    override void wordWrapRefresh()
    {
        _needRewrap = true;
    }

    override protected int lineCount()
    {
        return _content.length;
    }

    override protected void updateMaxLineWidth()
    {
        // find max line width. TODO: optimize!!!
        int maxw;
        int[] buf;
        for (int i = 0; i < _content.length; i++)
        {
            dstring s = _content[i];
            maxw = max(maxw, calcLineWidth(s));
        }
        _maxLineWidth = maxw;
    }

    protected bool _extendRightScrollBound = true;
    // TODO: `_maxLineWidth + (_extendRightScrollBound ? clientBox.width / 16 : 0)` add to fullContentSize?

    override protected void updateHScrollBar() // TODO: bug as in ScrollArea.updateScrollBars when delete text
    {
        _hscrollbar.setRange(0, _maxLineWidth + (_extendRightScrollBound ? clientBox.width / 16 : 0));
        _hscrollbar.pageSize = clientBox.width;
        _hscrollbar.position = _scrollPos.x;
    }

    override protected void updateVScrollBar()
    {
        // fully visible lines
        int visibleLines = _lineHeight ? max(clientBox.height / _lineHeight, 1) : 1;
        _vscrollbar.setRange(0, _content.length);
        _vscrollbar.pageSize = visibleLines;
        _vscrollbar.position = _firstVisibleLine;
    }

    override bool onHScroll(ScrollEvent event)
    {
        if (event.action == ScrollAction.sliderMoved || event.action == ScrollAction.sliderReleased)
        {
            if (_scrollPos.x != event.position)
            {
                _scrollPos.x = event.position;
                invalidate();
            }
        }
        else if (event.action == ScrollAction.pageUp)
        {
            scrollLeft();
        }
        else if (event.action == ScrollAction.pageDown)
        {
            scrollRight();
        }
        else if (event.action == ScrollAction.lineUp)
        {
            scrollLeft();
        }
        else if (event.action == ScrollAction.lineDown)
        {
            scrollRight();
        }
        return true;
    }

    override bool onVScroll(ScrollEvent event)
    {
        if (event.action == ScrollAction.sliderMoved || event.action == ScrollAction.sliderReleased)
        {
            if (_firstVisibleLine != event.position)
            {
                _firstVisibleLine = event.position;
                measureVisibleText();
                invalidate();
            }
        }
        else if (event.action == ScrollAction.pageUp)
        {
            scrollPageUp();
        }
        else if (event.action == ScrollAction.pageDown)
        {
            scrollPageDown();
        }
        else if (event.action == ScrollAction.lineUp)
        {
            scrollLineUp();
        }
        else if (event.action == ScrollAction.lineDown)
        {
            scrollLineDown();
        }
        return true;
    }

    override bool onKeyEvent(KeyEvent event)
    {
        bool noOtherModifiers = !(event.flags & (KeyFlag.alt | KeyFlag.menu));
        if (event.action == KeyAction.keyDown && noOtherModifiers)
        {
            TextPosition oldCaretPos = _caretPos;

            bool shiftPressed = !!(event.flags & KeyFlag.shift);
            bool controlPressed = !!(event.flags & KeyFlag.control);
            if (event.keyCode == KeyCode.up)
            {
                if (!controlPressed)
                {
                    // move cursor one line up (with selection when Shift pressed)
                    if (_caretPos.line > 0 || wordWrap)
                    {
                        if (_wordWrap)
                        {
                            LineSpan curSpan = getSpan(_caretPos.line);
                            int curWrap = findWrapLine(_caretPos);
                            if (curWrap > 0)
                            {
                                _caretPos.pos -= curSpan.wrapPoints[curWrap - 1].wrapPos;
                            }
                            else
                            {
                                int previousPos = _caretPos.pos;
                                curSpan = getSpan(_caretPos.line - 1);
                                curWrap = curSpan.len - 1;
                                if (curWrap > 0)
                                {
                                    int accumulativePoint = curSpan.accumulation(curSpan.len - 1,
                                            LineSpan.WrapPointInfo.position);
                                    _caretPos.line--;
                                    _caretPos.pos = accumulativePoint + previousPos;
                                }
                                else
                                {
                                    _caretPos.line--;
                                }
                            }
                        }
                        else if (_caretPos.line > 0)
                            _caretPos.line--;
                        correctCaretPos();
                        updateSelectionAfterCursorMovement(oldCaretPos, shiftPressed);
                        ensureCaretVisible();
                    }
                    return true;
                }
                else
                {
                    scrollLineUp();
                    return true;
                }
            }
            if (event.keyCode == KeyCode.down)
            {
                if (!controlPressed)
                {
                    // move cursor one line down (with selection when Shift pressed)
                    if (_caretPos.line < _content.length - 1)
                    {
                        if (_wordWrap)
                        {
                            LineSpan curSpan = getSpan(_caretPos.line);
                            int curWrap = findWrapLine(_caretPos);
                            if (curWrap < curSpan.len - 1)
                            {
                                int previousPos = _caretPos.pos;
                                _caretPos.pos += curSpan.wrapPoints[curWrap].wrapPos;
                                correctCaretPos();
                                if (_caretPos.pos == previousPos)
                                {
                                    _caretPos.pos = 0;
                                    _caretPos.line++;
                                }
                            }
                            else if (curSpan.len > 1)
                            {
                                int previousPos = _caretPos.pos;
                                int previousAccumulatedPosition = curSpan.accumulation(curSpan.len - 1,
                                        LineSpan.WrapPointInfo.position);
                                _caretPos.line++;
                                _caretPos.pos = previousPos - previousAccumulatedPosition;
                            }
                            else
                            {
                                _caretPos.line++;
                            }
                        }
                        else
                        {
                            _caretPos.line++;
                        }
                        correctCaretPos();
                        updateSelectionAfterCursorMovement(oldCaretPos, shiftPressed);
                        ensureCaretVisible();
                    }
                    return true;
                }
                else
                {
                    scrollLineDown();
                    return true;
                }
            }
        }
        return super.onKeyEvent(event);
    }

    override bool onMouseEvent(MouseEvent event)
    {
        if (event.action == MouseAction.wheel)
        {
            cancelHoverTimer();
            uint keyFlags = event.flags & (MouseFlag.shift | MouseFlag.control | MouseFlag.alt);
            if (event.wheelDelta < 0)
            {
                if (keyFlags == MouseFlag.shift)
                {
                    scrollRight();
                    return true;
                }
                if (keyFlags == MouseFlag.control)
                {
                    zoom(false);
                    return true;
                }
                scrollLineDown();
                return true;
            }
            else if (event.wheelDelta > 0)
            {
                if (keyFlags == MouseFlag.shift)
                {
                    scrollLeft();
                    return true;
                }
                if (keyFlags == MouseFlag.control)
                {
                    zoom(true);
                    return true;
                }
                scrollLineUp();
                return true;
            }
        }
        return super.onMouseEvent(event);
    }

    protected bool _enableScrollAfterText = true;
    override protected void ensureCaretVisible(bool center = false)
    {
        _caretPos.line = clamp(_caretPos.line, 0, _content.length - 1);
        int visibleLines = _lineHeight > 0 ? max(clientBox.height / _lineHeight, 1) : 1; // fully visible lines
        int maxFirstVisibleLine = _content.length - 1;
        if (!_enableScrollAfterText)
            maxFirstVisibleLine = _content.length - visibleLines;
        maxFirstVisibleLine = max(maxFirstVisibleLine, 0);

        if (_caretPos.line < _firstVisibleLine)
        {
            _firstVisibleLine = _caretPos.line;
            if (center)
            {
                _firstVisibleLine -= visibleLines / 2;
                _firstVisibleLine = max(_firstVisibleLine, 0);
            }
            _firstVisibleLine = min(_firstVisibleLine, maxFirstVisibleLine);
            measureVisibleText();
            invalidate();
        }
        else if (_wordWrap && !(_firstVisibleLine > maxFirstVisibleLine))
        {
            //For wordwrap mode, move down sooner
            int offsetLines = -1 * caretHeightOffset / _lineHeight;
            debug (editors)
                Log.d("offsetLines: ", offsetLines);
            if (_caretPos.line >= _firstVisibleLine + visibleLines - offsetLines)
            {
                _firstVisibleLine = _caretPos.line - visibleLines + 1 + offsetLines;
                if (center)
                    _firstVisibleLine += visibleLines / 2;
                _firstVisibleLine = min(_firstVisibleLine, maxFirstVisibleLine);
                _firstVisibleLine = max(_firstVisibleLine, 0);
                measureVisibleText();
                invalidate();
            }
        }
        else if (_caretPos.line >= _firstVisibleLine + visibleLines)
        {
            _firstVisibleLine = _caretPos.line - visibleLines + 1;
            if (center)
                _firstVisibleLine += visibleLines / 2;
            _firstVisibleLine = min(_firstVisibleLine, maxFirstVisibleLine);
            _firstVisibleLine = max(_firstVisibleLine, 0);
            measureVisibleText();
            invalidate();
        }
        else if (_firstVisibleLine > maxFirstVisibleLine)
        {
            _firstVisibleLine = maxFirstVisibleLine;
            _firstVisibleLine = max(_firstVisibleLine, 0);
            measureVisibleText();
            invalidate();
        }
        //_scrollPos
        Box b = textPosToClient(_caretPos);
        if (b.x < 0)
        {
            // scroll left
            _scrollPos.x -= -b.x + clientBox.width / 4;
            _scrollPos.x = max(_scrollPos.x, 0);
            invalidate();
        }
        else if (b.x >= clientBox.width - 10)
        {
            // scroll right
            if (!_wordWrap)
                _scrollPos.x += (b.x - clientBox.width) + clientBox.width / 4;
            invalidate();
        }
        updateScrollBars();
        handleEditorStateChange();
    }

    override protected Box textPosToClient(TextPosition p)
    {
        Box res;
        int lineIndex = p.line - _firstVisibleLine;
        res.y = lineIndex * _lineHeight;
        res.h = _lineHeight;
        // if visible
        if (lineIndex >= 0 && lineIndex < _visibleLines.length)
        {
            if (p.pos == 0)
                res.x = 0;
            else if (p.pos >= _visibleLinesMeasurement[lineIndex].length)
                res.x = _visibleLinesWidths[lineIndex];
            else
                res.x = _visibleLinesMeasurement[lineIndex][p.pos - 1];
        }
        res.x -= _scrollPos.x;
        res.w = 1;
        return res;
    }

    override protected TextPosition clientToTextPos(Point pt)
    {
        TextPosition res;
        pt.x += _scrollPos.x;
        int lineIndex = max(pt.y / _lineHeight, 0);
        if (lineIndex < _visibleLines.length)
        {
            res.line = lineIndex + _firstVisibleLine;
            int len = cast(int)_visibleLines[lineIndex].length;
            for (int i = 0; i < len; i++)
            {
                int x0 = i > 0 ? _visibleLinesMeasurement[lineIndex][i - 1] : 0;
                int x1 = _visibleLinesMeasurement[lineIndex][i];
                int mx = (x0 + x1) >> 1;
                if (pt.x <= mx)
                {
                    res.pos = i;
                    return res;
                }
            }
            res.pos = cast(int)_visibleLines[lineIndex].length;
        }
        else if (_visibleLines.length > 0)
        {
            res.line = _firstVisibleLine + cast(int)_visibleLines.length - 1;
            res.pos = cast(int)_visibleLines[$ - 1].length;
        }
        else
        {
            res.line = 0;
            res.pos = 0;
        }
        return res;
    }

    //===============================================================
    // Actions

    /// Zoom in when `zoomIn` is true and out vice versa, if supported by an editor
    void zoom(bool zoomIn)
    {
        int dir = zoomIn ? 1 : -1;
        if (_minFontSize < _maxFontSize && _minFontSize > 0 && _maxFontSize > 0)
        {
            int currentFontSize = fontSize;
            int increment = currentFontSize >= 30 ? 2 : 1;
            int newFontSize = currentFontSize + increment * dir; //* 110 / 100;
            if (newFontSize > 30)
                newFontSize &= 0xFFFE;
            if (currentFontSize != newFontSize && newFontSize <= _maxFontSize && newFontSize >= _minFontSize)
            {
                debug (editors)
                    Log.i("Font size in editor ", id, " zoomed to ", newFontSize);
                fontSize = cast(ushort)newFontSize;
                updateFontProps();
                _needRewrap = true;
                measureVisibleText();
                updateScrollBars();
                invalidate();
            }
        }
    }

    protected void PageBegin(bool select)
    {
        TextPosition oldCaretPos = _caretPos;
        ensureCaretVisible();
        _caretPos.line = _firstVisibleLine;
        correctCaretPos();
        updateSelectionAfterCursorMovement(oldCaretPos, select);
    }
    protected void PageEnd(bool select)
    {
        TextPosition oldCaretPos = _caretPos;
        ensureCaretVisible();
        int fullLines = clientBox.height / _lineHeight;
        int newpos = _firstVisibleLine + fullLines - 1;
        if (newpos >= _content.length)
            newpos = _content.length - 1;
        _caretPos.line = newpos;
        correctCaretPos();
        updateSelectionAfterCursorMovement(oldCaretPos, select);
    }
    protected void PageUp(bool select)
    {
        TextPosition oldCaretPos = _caretPos;
        ensureCaretVisible();
        int fullLines = clientBox.height / _lineHeight;
        int newpos = _firstVisibleLine - fullLines;
        if (newpos < 0)
        {
            _firstVisibleLine = 0;
            _caretPos.line = 0;
        }
        else
        {
            int delta = _firstVisibleLine - newpos;
            _firstVisibleLine = newpos;
            _caretPos.line -= delta;
        }
        correctCaretPos();
        measureVisibleText();
        updateScrollBars();
        updateSelectionAfterCursorMovement(oldCaretPos, select);
    }
    protected void PageDown(bool select)
    {
        TextPosition oldCaretPos = _caretPos;
        ensureCaretVisible();
        int fullLines = clientBox.height / _lineHeight;
        int newpos = _firstVisibleLine + fullLines;
        if (newpos >= _content.length)
        {
            _caretPos.line = _content.length - 1;
        }
        else
        {
            int delta = newpos - _firstVisibleLine;
            _firstVisibleLine = newpos;
            _caretPos.line += delta;
        }
        correctCaretPos();
        measureVisibleText();
        updateScrollBars();
        updateSelectionAfterCursorMovement(oldCaretPos, select);
    }

    protected void ToggleLineComment()
    {
        if (!readOnly && _content.syntaxSupport && _content.syntaxSupport.supportsToggleLineComment &&
                _content.syntaxSupport.canToggleLineComment(_selectionRange))
            _content.syntaxSupport.toggleLineComment(_selectionRange, this);
    }
    protected void ToggleBlockComment()
    {
        if (!readOnly && _content.syntaxSupport && _content.syntaxSupport.supportsToggleBlockComment &&
                _content.syntaxSupport.canToggleBlockComment(_selectionRange))
            _content.syntaxSupport.toggleBlockComment(_selectionRange, this);
    }

    protected void InsertNewLine()
    {
        if (!readOnly)
        {
            correctCaretPos();
            auto op = new EditOperation(EditAction.replace, _selectionRange, [""d, ""d]);
            _content.performOperation(op, this);
        }
    }
    protected void PrependNewLine()
    {
        if (!readOnly)
        {
            correctCaretPos();
            _caretPos.pos = 0;
            auto op = new EditOperation(EditAction.replace, _selectionRange, [""d, ""d]);
            _content.performOperation(op, this);
        }
    }
    protected void AppendNewLine()
    {
        if (!readOnly)
        {
            TextPosition oldCaretPos = _caretPos;
            correctCaretPos();
            TextPosition p = _content.lineEnd(_caretPos.line);
            TextRange r = TextRange(p, p);
            auto op = new EditOperation(EditAction.replace, r, [""d, ""d]);
            _content.performOperation(op, this);
            _caretPos = oldCaretPos;
            handleEditorStateChange();
        }
    }
    protected void DeleteLine()
    {
        if (!readOnly)
        {
            correctCaretPos();
            auto op = new EditOperation(EditAction.replace, _content.lineRange(_caretPos.line), [""d]);
            _content.performOperation(op, this);
        }
    }

    //   TODO: merge them       -------------------------------------
    /// Scroll window left
    protected void scrollLeft()
    {
        if (_scrollPos.x > 0)
        {
            _scrollPos.x = max(_scrollPos.x - _spaceWidth * 4, 0);
            updateScrollBars();
            invalidate();
        }
    }

    /// Scroll window right
    protected void scrollRight()
    {
        if (_scrollPos.x < _maxLineWidth - clientBox.width)
        {
            _scrollPos.x = min(_scrollPos.x + _spaceWidth * 4, _maxLineWidth - clientBox.width);
            updateScrollBars();
            invalidate();
        }
    }

    /// Scroll one line up (not changing cursor)
    protected void scrollLineUp()
    {
        if (_firstVisibleLine > 0)
        {
            _firstVisibleLine = max(_firstVisibleLine - 3, 0);
            measureVisibleText();
            updateScrollBars();
            invalidate();
        }
    }

    /// Scroll one page up (not changing cursor)
    protected void scrollPageUp()
    {
        int fullLines = clientBox.height / _lineHeight;
        if (_firstVisibleLine > 0)
        {
            _firstVisibleLine = max(_firstVisibleLine - fullLines * 3 / 4, 0);
            measureVisibleText();
            updateScrollBars();
            invalidate();
        }
    }

    /// Scroll one line down (not changing cursor)
    protected void scrollLineDown()
    {
        int fullLines = clientBox.height / _lineHeight;
        if (_firstVisibleLine + fullLines < _content.length)
        {
            _firstVisibleLine = max(min(
                _firstVisibleLine + 3, _content.length - fullLines), 0);
            measureVisibleText();
            updateScrollBars();
            invalidate();
        }
    }

    /// Scroll one page down (not changing cursor)
    protected void scrollPageDown()
    {
        int fullLines = clientBox.height / _lineHeight;
        if (_firstVisibleLine + fullLines < _content.length)
        {
            _firstVisibleLine = max(min(
                _firstVisibleLine + fullLines * 3 / 4, _content.length - fullLines), 0);
            measureVisibleText();
            updateScrollBars();
            invalidate();
        }
    }

    //===============================================================

    protected void highlightTextPattern(DrawBuf buf, int lineIndex, Rect lineRect, Rect visibleRect)
    {
        dstring pattern = _textToHighlight;
        uint options = _textToHighlightOptions;
        if (!pattern.length)
        {
            // support highlighting selection text - if whole word is selected
            if (_selectionRange.empty || !_selectionRange.singleLine)
                return;
            if (_selectionRange.start.line >= _content.length)
                return;
            dstring selLine = _content.line(_selectionRange.start.line);
            int start = _selectionRange.start.pos;
            int end = _selectionRange.end.pos;
            if (start >= selLine.length)
                return;
            pattern = selLine[start .. end];
            if (!isWordChar(pattern[0]) || !isWordChar(pattern[$ - 1]))
                return;
            if (!isWholeWord(selLine, start, end))
                return;
            // whole word is selected - enable highlight for it
            options = TextSearchFlag.caseSensitive | TextSearchFlag.wholeWords;
        }
        if (!pattern.length)
            return;
        dstring lineText = _content.line(lineIndex);
        if (lineText.length < pattern.length)
            return;
        ptrdiff_t start = 0;
        import std.string : indexOf, CaseSensitive;
        import std.typecons : Yes, No;

        bool caseSensitive = (options & TextSearchFlag.caseSensitive) != 0;
        bool wholeWords = (options & TextSearchFlag.wholeWords) != 0;
        bool selectionOnly = (options & TextSearchFlag.selectionOnly) != 0;
        while (true)
        {
            ptrdiff_t pos = lineText[start .. $].indexOf(pattern, caseSensitive ? Yes.caseSensitive : No.caseSensitive);
            if (pos < 0)
                break;
            // found text to highlight
            start += pos;
            if (!wholeWords || isWholeWord(lineText, start, start + pattern.length))
            {
                TextRange r = TextRange(TextPosition(lineIndex, cast(int)start),
                        TextPosition(lineIndex, cast(int)(start + pattern.length)));
                uint color = r.isInsideOrNext(caretPos) ? _searchHighlightColorCurrent : _searchHighlightColorOther;
                highlightLineRange(buf, lineRect, color, r);
            }
            start += pattern.length;
        }
    }

    static bool isValidWordBound(dchar innerChar, dchar outerChar)
    {
        return !isWordChar(innerChar) || !isWordChar(outerChar);
    }
    /// Returns true if selected range of string is whole word
    static bool isWholeWord(dstring lineText, size_t start, size_t end)
    {
        if (start >= lineText.length || start >= end)
            return false;
        if (start > 0 && !isValidWordBound(lineText[start], lineText[start - 1]))
            return false;
        if (end > 0 && end < lineText.length && !isValidWordBound(lineText[end - 1], lineText[end]))
            return false;
        return true;
    }

    /// Find all occurences of text pattern in content; options = bitset of TextSearchFlag
    TextRange[] findAll(dstring pattern, uint options)
    {
        TextRange[] res;
        res.assumeSafeAppend();
        if (!pattern.length)
            return res;
        import std.string : indexOf, CaseSensitive;
        import std.typecons : Yes, No;

        bool caseSensitive = (options & TextSearchFlag.caseSensitive) != 0;
        bool wholeWords = (options & TextSearchFlag.wholeWords) != 0;
        bool selectionOnly = (options & TextSearchFlag.selectionOnly) != 0;
        for (int i = 0; i < _content.length; i++)
        {
            dstring lineText = _content.line(i);
            if (lineText.length < pattern.length)
                continue;
            ptrdiff_t start = 0;
            while (true)
            {
                ptrdiff_t pos = lineText[start .. $].indexOf(pattern, caseSensitive ?
                        Yes.caseSensitive : No.caseSensitive);
                if (pos < 0)
                    break;
                // found text to highlight
                start += pos;
                if (!wholeWords || isWholeWord(lineText, start, start + pattern.length))
                {
                    TextRange r = TextRange(TextPosition(i, cast(int)start), TextPosition(i,
                            cast(int)(start + pattern.length)));
                    res ~= r;
                }
                start += _textToHighlight.length;
            }
        }
        return res;
    }

    /// Find next occurence of text pattern in content, returns true if found
    bool findNextPattern(ref TextPosition pos, dstring pattern, uint searchOptions, int direction)
    {
        TextRange[] all = findAll(pattern, searchOptions);
        if (!all.length)
            return false;
        int currentIndex = -1;
        int nearestIndex = cast(int)all.length;
        for (int i = 0; i < all.length; i++)
        {
            if (all[i].isInsideOrNext(pos))
            {
                currentIndex = i;
                break;
            }
        }
        for (int i = 0; i < all.length; i++)
        {
            if (pos < all[i].start)
            {
                nearestIndex = i;
                break;
            }
            if (pos > all[i].end)
            {
                nearestIndex = i + 1;
            }
        }
        if (currentIndex >= 0)
        {
            if (all.length < 2 && direction != 0)
                return false;
            currentIndex += direction;
            if (currentIndex < 0)
                currentIndex = cast(int)all.length - 1;
            else if (currentIndex >= all.length)
                currentIndex = 0;
            pos = all[currentIndex].start;
            return true;
        }
        if (direction < 0)
            nearestIndex--;
        if (nearestIndex < 0)
            nearestIndex = cast(int)all.length - 1;
        else if (nearestIndex >= all.length)
            nearestIndex = 0;
        pos = all[nearestIndex].start;
        return true;
    }

    protected void highlightLineRange(DrawBuf buf, Rect lineRect, uint color, TextRange r)
    {
        Box start = textPosToClient(r.start);
        Box end = textPosToClient(r.end);
        Rect rc = lineRect;
        rc.left = clientBox.x + start.x;
        rc.right = clientBox.x + end.x + end.w;
        if (_wordWrap && !rc.empty)
        {
            wordWrapFillRect(buf, r.start.line, rc, color);
        }
        else if (!rc.empty)
        {
            // draw selection rect for matching bracket
            buf.fillRect(rc, color);
        }
    }

    /// Used in place of directly calling buf.fillRect in word wrap mode
    void wordWrapFillRect(DrawBuf buf, int line, Rect lineToDivide, uint color)
    {
        Rect rc = lineToDivide;
        auto limitNumber = (int num, int limit) => num > limit ? limit : num;
        LineSpan curSpan = getSpan(line);
        int yOffset = _lineHeight * (wrapsUpTo(line));
        rc.offset(0, yOffset);
        Rect[] wrappedSelection;
        wrappedSelection.length = curSpan.len;
        foreach (int i, wrapLineRect; wrappedSelection)
        {
            int startingDifference = rc.left - clientBox.x;
            wrapLineRect = rc;
            wrapLineRect.offset(-1 * curSpan.accumulation(i, LineSpan.WrapPointInfo.width), i * _lineHeight);
            wrapLineRect.right = limitNumber(wrapLineRect.right,
                    (rc.left + curSpan.wrapPoints[i].wrapWidth) - startingDifference);
            buf.fillRect(wrapLineRect, color);
        }
    }

    override Size fullContentSize()
    {
        return Size(_maxLineWidth, _lineHeight * _content.length);
    }

    override Size computeMinSize()
    {
        FontRef f = font();
        f.measureMultilineText(_minSizeTester, 0, MAX_WIDTH_UNSPECIFIED);
        return _measuredMinSize;
    }

    override Boundaries computeBoundaries()
    {
        updateFontProps();
        updateMaxLineWidth();
        return super.computeBoundaries();
    }

    override void layout(Box geom)
    {
        _needLayout = false;
        if (visibility == Visibility.gone)
            return;

        if (geom != _box)
            _contentChanged = true;

        Box content = geom;
        if (_findPanel && _findPanel.visibility != Visibility.gone)
        {
            Size sz = _findPanel.computeBoundaries().nat;
            _findPanel.layout(Box(geom.x, geom.y + geom.h - sz.h, geom.w, sz.h));
            content.h -= sz.h;
        }

        super.layout(content);
        if (_contentChanged)
        {
            measureVisibleText();
            _needRewrap = true;
            _contentChanged = false;
        }

        _box = geom;
    }

    override protected Size measureVisibleText()
    {
        FontRef font = font();
        _lineHeight = font.height;
        _numVisibleLines = (clientBox.height + _lineHeight - 1) / _lineHeight;
        if (_firstVisibleLine >= _content.length)
        {
            _firstVisibleLine = max(_content.length - _numVisibleLines + 1, 0);
            _caretPos.line = _content.length - 1;
            _caretPos.pos = 0;
        }
        _numVisibleLines = max(_numVisibleLines, 1);
        if (_firstVisibleLine + _numVisibleLines > _content.length)
            _numVisibleLines = _content.length - _firstVisibleLine;
        _numVisibleLines = max(_numVisibleLines, 1);
        _visibleLines.length = _numVisibleLines;
        if (_visibleLinesMeasurement.length < _numVisibleLines)
            _visibleLinesMeasurement.length = _numVisibleLines;
        if (_visibleLinesWidths.length < _numVisibleLines)
            _visibleLinesWidths.length = _numVisibleLines;
        if (_visibleLinesHighlights.length < _numVisibleLines)
        {
            _visibleLinesHighlights.length = _numVisibleLines;
            _visibleLinesHighlightsBuf.length = _numVisibleLines;
        }
        Size sz;
        for (int i = 0; i < _numVisibleLines; i++)
        {
            _visibleLines[i] = _content[_firstVisibleLine + i];
            size_t len = _visibleLines[i].length;
            if (_visibleLinesMeasurement[i].length < len)
                _visibleLinesMeasurement[i].length = len;
            if (_visibleLinesHighlightsBuf[i].length < len)
                _visibleLinesHighlightsBuf[i].length = len;
            _visibleLinesHighlights[i] = handleCustomLineHighlight(_firstVisibleLine + i,
                    _visibleLines[i], _visibleLinesHighlightsBuf[i]);
            int charsMeasured = font.measureText(_visibleLines[i], _visibleLinesMeasurement[i], int.max, tabSize);
            _visibleLinesWidths[i] = charsMeasured > 0 ? _visibleLinesMeasurement[i][charsMeasured - 1] : 0;
            // width - max from visible lines
            sz.w = max(sz.w, _visibleLinesWidths[i]);
        }
        sz.w = _maxLineWidth;
        sz.h = _lineHeight * _content.length; // height - for all lines
        return sz;
    }

    /// Override to custom highlight of line background
    protected void drawLineBackground(DrawBuf buf, int lineIndex, Rect lineRect, Rect visibleRect)
    {
        // highlight odd lines
        //if ((lineIndex & 1))
        //    buf.fillRect(visibleRect, 0xF4808080);

        if (!_selectionRange.empty && _selectionRange.start.line <= lineIndex && _selectionRange.end.line >= lineIndex)
        {
            // line inside selection
            int selStart = textPosToClient(_selectionRange.start).x;
            int selEnd = textPosToClient(_selectionRange.end).x;
            int startx = lineIndex == _selectionRange.start.line ? selStart + clientBox.x : lineRect.left;
            int endx = lineIndex == _selectionRange.end.line ? selEnd + clientBox.x
                : lineRect.right + _spaceWidth;
            Rect rc = lineRect;
            rc.left = startx;
            rc.right = endx;
            if (!rc.empty && _wordWrap)
            {
                wordWrapFillRect(buf, lineIndex, rc, focused ? _selectionColorFocused : _selectionColorNormal);
            }
            else if (!rc.empty)
            {
                // draw selection rect for line
                buf.fillRect(rc, focused ? _selectionColorFocused : _selectionColorNormal);
            }
        }

        highlightTextPattern(buf, lineIndex, lineRect, visibleRect);

        if (_matchingBraces.start.line == lineIndex)
        {
            TextRange r = TextRange(_matchingBraces.start, _matchingBraces.start.offset(1));
            highlightLineRange(buf, lineRect, _matchingBracketHightlightColor, r);
        }
        if (_matchingBraces.end.line == lineIndex)
        {
            TextRange r = TextRange(_matchingBraces.end, _matchingBraces.end.offset(1));
            highlightLineRange(buf, lineRect, _matchingBracketHightlightColor, r);
        }

        // frame around current line
        if (focused && lineIndex == _caretPos.line && _selectionRange.singleLine &&
                _selectionRange.start.line == _caretPos.line)
        {
            //TODO: Figure out why a little slow to catch up
            if (_wordWrap)
                visibleRect.offset(0, -caretHeightOffset);
            buf.drawFrame(visibleRect, 0xA0808080, RectOffset(1));
        }
    }

    override protected void drawExtendedArea(DrawBuf buf)
    {
        if (_leftPaneWidth <= 0)
            return;

        Box cb = clientBox;
        Box lineBox = Box(cb.x - _leftPaneWidth, cb.y, _leftPaneWidth, _lineHeight);
        int i = _firstVisibleLine;
        int lc = lineCount;
        while (true)
        {
            if (lineBox.y > cb.y + cb.h)
                break;
            drawLeftPane(buf, Rect(lineBox), i < lc ? i : -1);
            lineBox.y += _lineHeight;
            if (_wordWrap)
            {
                int currentWrap = 1;
                while (true)
                {
                    LineSpan curSpan = getSpan(i);
                    if (currentWrap > curSpan.len - 1)
                        break;
                    if (lineBox.y > cb.y + cb.h)
                        break;
                    drawLeftPane(buf, Rect(lineBox), -1);
                    lineBox.y += _lineHeight;

                    currentWrap++;
                }
            }
            i++;
        }
    }

    protected CustomCharProps[ubyte] _tokenHighlightColors;

    /// Set highlight options for particular token category
    void setTokenHightlightColor(ubyte tokenCategory, uint color, bool underline = false, bool strikeThrough = false)
    {
        _tokenHighlightColors[tokenCategory] = CustomCharProps(color, underline, strikeThrough);
    }
    /// Clear highlight colors
    void clearTokenHightlightColors()
    {
        destroy(_tokenHighlightColors);
    }

    /**
        Custom text color and style highlight (using text highlight) support.

        Return null if no syntax highlight required for line.
     */
    protected CustomCharProps[] handleCustomLineHighlight(int line, dstring txt, ref CustomCharProps[] buf)
    {
        if (!_tokenHighlightColors)
            return null; // no highlight colors set
        TokenPropString tokenProps = _content.lineTokenProps(line);
        if (tokenProps.length > 0)
        {
            bool hasNonzeroTokens = false;
            foreach (t; tokenProps)
                if (t)
                {
                    hasNonzeroTokens = true;
                    break;
                }
            if (!hasNonzeroTokens)
                return null; // all characters are of unknown token type (or white space)
            if (buf.length < tokenProps.length)
                buf.length = tokenProps.length;
            CustomCharProps[] colors = buf[0 .. tokenProps.length]; //new CustomCharProps[tokenProps.length];
            for (int i = 0; i < tokenProps.length; i++)
            {
                ubyte p = tokenProps[i];
                if (p in _tokenHighlightColors)
                    colors[i] = _tokenHighlightColors[p];
                else if ((p & TOKEN_CATEGORY_MASK) in _tokenHighlightColors)
                    colors[i] = _tokenHighlightColors[(p & TOKEN_CATEGORY_MASK)];
                else
                    colors[i].color = textColor;
                if (isFullyTransparentColor(colors[i].color))
                    colors[i].color = textColor;
            }
            return colors;
        }
        return null;
    }

    TextRange _matchingBraces;

    /// Find max tab mark column position for line
    protected int findMaxTabMarkColumn(int lineIndex)
    {
        if (lineIndex < 0 || lineIndex >= content.length)
            return -1;
        int maxSpace = -1;
        auto space = content.getLineWhiteSpace(lineIndex);
        maxSpace = space.firstNonSpaceColumn;
        if (maxSpace >= 0)
            return maxSpace;
        for (int i = lineIndex - 1; i >= 0; i--)
        {
            space = content.getLineWhiteSpace(i);
            if (!space.empty)
            {
                maxSpace = space.firstNonSpaceColumn;
                break;
            }
        }
        for (int i = lineIndex + 1; i < content.length; i++)
        {
            space = content.getLineWhiteSpace(i);
            if (!space.empty)
            {
                if (maxSpace < 0 || maxSpace < space.firstNonSpaceColumn)
                    maxSpace = space.firstNonSpaceColumn;
                break;
            }
        }
        return maxSpace;
    }

    void drawTabPositionMarks(DrawBuf buf, ref FontRef font, int lineIndex, Rect lineRect)
    {
        int maxCol = findMaxTabMarkColumn(lineIndex);
        if (maxCol > 0)
        {
            int spaceWidth = font.charWidth(' ');
            Rect rc = lineRect;
            uint color = addAlpha(textColor, 0xC0);
            for (int i = 0; i < maxCol; i += tabSize)
            {
                rc.left = lineRect.left + i * spaceWidth;
                rc.right = rc.left + 1;
                buf.fillRectPattern(rc, color, PatternType.dotted);
            }
        }
    }

    void drawWhiteSpaceMarks(DrawBuf buf, ref FontRef font, dstring txt, int tabSize, Rect lineRect, Rect visibleRect)
    {
        // _showTabPositionMarks
        // _showWhiteSpaceMarks
        int firstNonSpace = -1;
        int lastNonSpace = -1;
        bool hasTabs = false;
        for (int i = 0; i < txt.length; i++)
        {
            if (txt[i] == '\t')
            {
                hasTabs = true;
            }
            else if (txt[i] != ' ')
            {
                if (firstNonSpace == -1)
                    firstNonSpace = i;
                lastNonSpace = i + 1;
            }
        }
        bool spacesOnly = txt.length > 0 && firstNonSpace < 0;
        if (firstNonSpace <= 0 && lastNonSpace >= txt.length && !hasTabs && !spacesOnly)
            return;
        uint color = addAlpha(textColor, 0xC0);
        static int[] textSizeBuffer;
        int charsMeasured = font.measureText(txt, textSizeBuffer, MAX_WIDTH_UNSPECIFIED, tabSize, 0, 0);
        int ts = clamp(tabSize, 1, 8);
        int spaceIndex = 0;
        for (int i = 0; i < txt.length && i < charsMeasured; i++)
        {
            dchar ch = txt[i];
            bool outsideText = (i < firstNonSpace || i >= lastNonSpace || spacesOnly);
            if ((ch == ' ' && outsideText) || ch == '\t')
            {
                Rect rc = lineRect;
                rc.left = lineRect.left + (i > 0 ? textSizeBuffer[i - 1] : 0);
                rc.right = lineRect.left + textSizeBuffer[i];
                int h = rc.height;
                if (rc.intersects(visibleRect))
                {
                    // draw space mark
                    if (ch == ' ')
                    {
                        // space
                        int sz = h / 6;
                        if (sz < 1)
                            sz = 1;
                        rc.top += h / 2 - sz / 2;
                        rc.bottom = rc.top + sz;
                        rc.left += rc.width / 2 - sz / 2;
                        rc.right = rc.left + sz;
                        buf.fillRect(rc, color);
                    }
                    else if (ch == '\t')
                    {
                        // tab
                        Point p1 = Point(rc.left + 1, rc.top + h / 2);
                        Point p2 = p1;
                        p2.x = rc.right - 1;
                        int sz = h / 4;
                        if (sz < 2)
                            sz = 2;
                        if (sz > p2.x - p1.x)
                            sz = p2.x - p1.x;
                        buf.drawLine(p1, p2, color);
                        buf.drawLine(p2, Point(p2.x - sz, p2.y - sz), color);
                        buf.drawLine(p2, Point(p2.x - sz, p2.y + sz), color);
                    }
                }
            }
        }
    }

    /// Clear _span
    void resetVisibleSpans()
    {
        //TODO: Don't erase spans which have not been modified, cache them
        _span = [];
    }

    private bool _needRewrap = true;
    private int lastStartingLine;

    override protected void drawClient(DrawBuf buf)
    {
        // update matched braces
        if (!content.findMatchedBraces(_caretPos, _matchingBraces))
        {
            _matchingBraces.start.line = -1;
            _matchingBraces.end.line = -1;
        }

        Box b = clientBox;

        if (_contentChanged)
            _needRewrap = true;
        if (lastStartingLine != _firstVisibleLine)
        {
            _needRewrap = true;
            lastStartingLine = _firstVisibleLine;
        }
        if (b.width <= 0 && _wordWrap)
        {
            //Prevent drawClient from getting stuck in loop
            return;
        }
        bool doRewrap = false;
        if (_needRewrap && _wordWrap)
        {
            resetVisibleSpans();
            _needRewrap = false;
            doRewrap = true;
        }

        FontRef font = font();
        int previousWraps;
        for (int i = 0; i < _visibleLines.length; i++)
        {
            dstring txt = _visibleLines[i];
            Rect lineRect;
            lineRect.left = clientBox.x - _scrollPos.x;
            lineRect.right = lineRect.left + calcLineWidth(_content[_firstVisibleLine + i]);
            lineRect.top = clientBox.y + i * _lineHeight;
            lineRect.bottom = lineRect.top + _lineHeight;
            Rect visibleRect = lineRect;
            visibleRect.left = clientBox.x;
            visibleRect.right = clientBox.x + clientBox.w;
            drawLineBackground(buf, _firstVisibleLine + i, lineRect, visibleRect);
            if (_showTabPositionMarks)
                drawTabPositionMarks(buf, font, _firstVisibleLine + i, lineRect);
            if (!txt.length && !_wordWrap)
                continue;
            if (_showWhiteSpaceMarks)
            {
                Rect whiteSpaceRc = lineRect;
                Rect whiteSpaceRcVisible = visibleRect;
                for (int z; z < previousWraps; z++)
                {
                    whiteSpaceRc.offset(0, _lineHeight);
                    whiteSpaceRcVisible.offset(0, _lineHeight);
                }
                drawWhiteSpaceMarks(buf, font, txt, tabSize, whiteSpaceRc, whiteSpaceRcVisible);
            }
            if (_leftPaneWidth > 0)
            {
                Rect leftPaneRect = visibleRect;
                leftPaneRect.right = leftPaneRect.left;
                leftPaneRect.left -= _leftPaneWidth;
                drawLeftPane(buf, leftPaneRect, 0);
            }
            if (txt.length > 0 || _wordWrap)
            {
                CustomCharProps[] highlight = _visibleLinesHighlights[i];
                if (_wordWrap)
                {
                    dstring[] wrappedLine;
                    if (doRewrap)
                        wrappedLine = wrapLine(txt, _firstVisibleLine + i);
                    else if (i < _span.length)
                        wrappedLine = _span[i].wrappedContent;
                    int accumulativeLength;
                    CustomCharProps[] wrapProps;
                    foreach (int q, curWrap; wrappedLine)
                    {
                        auto lineOffset = q + i + wrapsUpTo(i + _firstVisibleLine);
                        if (highlight)
                        {
                            wrapProps = highlight[accumulativeLength .. $];
                            accumulativeLength += curWrap.length;
                            font.drawColoredText(buf, b.x - _scrollPos.x,
                                    b.y + lineOffset * _lineHeight, curWrap, wrapProps, tabSize);
                        }
                        else
                            font.drawText(buf, b.x - _scrollPos.x,
                                    b.y + lineOffset * _lineHeight, curWrap, textColor, tabSize);

                    }
                    previousWraps += to!int(wrappedLine.length - 1);
                }
                else
                {
                    if (highlight)
                        font.drawColoredText(buf, b.x - _scrollPos.x, b.y + i * _lineHeight,
                                txt, highlight, tabSize);
                    else
                        font.drawText(buf, b.x - _scrollPos.x, b.y + i * _lineHeight, txt, textColor, tabSize);
                }
            }
        }

        drawCaret(buf);
    }

    protected FindPanel _findPanel;

    dstring selectionText(bool singleLineOnly = false)
    {
        TextRange range = _selectionRange;
        if (range.empty)
        {
            return null;
        }
        dstring res = getRangeText(range);
        if (singleLineOnly)
        {
            for (int i = 0; i < res.length; i++)
            {
                if (res[i] == '\n')
                {
                    res = res[0 .. i];
                    break;
                }
            }
        }
        return res;
    }

    protected void findNext(bool backward)
    {
        createFindPanel(false, false);
        _findPanel.findNext(backward);
        // don't change replace mode
    }

    protected void openFindPanel()
    {
        createFindPanel(false, false);
        _findPanel.replaceMode = false;
        _findPanel.activate();
    }

    protected void openReplacePanel()
    {
        createFindPanel(false, true);
        _findPanel.replaceMode = true;
        _findPanel.activate();
    }

    /// Create find panel; returns true if panel was not yet visible
    protected bool createFindPanel(bool selectionOnly, bool replaceMode)
    {
        bool res = false;
        dstring txt = selectionText(true);
        if (!_findPanel)
        {
            _findPanel = new FindPanel(this, selectionOnly, replaceMode, txt);
            addChild(_findPanel);
            res = true;
        }
        else
        {
            if (_findPanel.visibility != Visibility.visible)
            {
                _findPanel.visibility = Visibility.visible;
                if (txt.length)
                    _findPanel.searchText = txt;
                res = true;
            }
        }
        requestLayout();
        return res;
    }

    /// Close find panel
    protected void closeFindPanel(bool hideOnly = true)
    {
        if (_findPanel)
        {
            setFocus();
            if (hideOnly)
            {
                _findPanel.visibility = Visibility.gone;
            }
            else
            {
                removeChild(_findPanel);
                destroy(_findPanel);
                _findPanel = null;
                requestLayout();
            }
        }
    }

    override void onDraw(DrawBuf buf)
    {
        if (visibility != Visibility.visible)
            return;
        super.onDraw(buf);
        if (_findPanel && _findPanel.visibility == Visibility.visible)
        {
            _findPanel.onDraw(buf);
        }
    }
}

/// Read only edit box for displaying logs with lines append operation
class LogWidget : EditBox
{
    @property
    {
        /// Max lines to show (when appended more than max lines, older lines will be truncated), 0 means no limit
        int maxLines() const
        {
            return _maxLines;
        }
        /// ditto
        LogWidget maxLines(int n)
        {
            _maxLines = n;
            return this;
        }

        /// When true, automatically scrolls down when new lines are appended (usually being reset by scrollbar interaction)
        bool scrollLock() const
        {
            return _scrollLock;
        }
        /// ditto
        LogWidget scrollLock(bool flag)
        {
            _scrollLock = flag;
            return this;
        }
    }

    protected int _maxLines;
    protected bool _scrollLock;

    this()
    {
        _scrollLock = true;
        _enableScrollAfterText = false;
        enabled = false;
        minFontSize(6.pt).maxFontSize(32.pt); // allow font zoom with Ctrl + MouseWheel
        onThemeChanged();
    }

    /// Append lines to the end of text
    void appendText(dstring text)
    {
        import std.array : split;

        if (text.length == 0)
            return;
        dstring[] lines = text.split("\n");
        //lines ~= ""d; // append new line after last line
        content.appendLines(lines);
        if (_maxLines > 0 && lineCount > _maxLines)
        {
            TextRange range;
            range.end.line = lineCount - _maxLines;
            auto op = new EditOperation(EditAction.replace, range, [""d]);
            _content.performOperation(op, this);
            _contentChanged = true;
        }
        updateScrollBars();
        if (_scrollLock)
        {
            _caretPos = lastLineBegin();
            ensureCaretVisible();
        }
    }

    TextPosition lastLineBegin()
    {
        TextPosition res;
        if (_content.length == 0)
            return res;
        if (_content.lineLength(_content.length - 1) == 0 && _content.length > 1)
            res.line = _content.length - 2;
        else
            res.line = _content.length - 1;
        return res;
    }

    override void layout(Box geom)
    {
        _needLayout = false;
        if (visibility == Visibility.gone)
            return;

        super.layout(geom);
        if (_scrollLock)
        {
            measureVisibleText();
            _caretPos = lastLineBegin();
            ensureCaretVisible();
        }
    }
}

class FindPanel : Row
{
    @property
    {
        /// Returns true if panel is working in replace mode
        bool replaceMode()
        {
            return _replaceMode;
        }

        FindPanel replaceMode(bool newMode)
        {
            if (newMode != _replaceMode)
            {
                _replaceMode = newMode;
                childByID("replace").visibility = newMode ? Visibility.visible : Visibility.gone;
            }
            return this;
        }

        dstring searchText()
        {
            return _edFind.text;
        }

        FindPanel searchText(dstring newText)
        {
            _edFind.text = newText;
            return this;
        }
    }

    protected
    {
        EditBox _editor;
        EditLine _edFind;
        EditLine _edReplace;
        Button _cbCaseSensitive;
        Button _cbWholeWords;
        CheckBox _cbSelection;
        Button _btnFindNext;
        Button _btnFindPrev;
        Button _btnReplace;
        Button _btnReplaceAndFind;
        Button _btnReplaceAll;
        Button _btnClose;
        bool _replaceMode;
    }

    this(EditBox editor, bool selectionOnly, bool replace, dstring initialText = ""d)
    {
        _replaceMode = replace;
        import beamui.dml.parser;

        try
        {
            parseML(q{
                {
                    fillsWidth: true
                    padding: 4pt
                    Column {
                        fillsWidth: true
                        Row {
                            fillsWidth: true
                            EditLine { id: edFind; fillsWidth: true; alignment: vcenter }
                            Button { id: btnFindNext; text: EDIT_FIND_NEXT }
                            Button { id: btnFindPrev; text: EDIT_FIND_PREV }
                            Column {
                                VSpacer {}
                                Row {
                                    Button {
                                        id: cbCaseSensitive
                                        checkable: true
                                        drawableID: "find_case_sensitive"
                                        tooltipText: EDIT_FIND_CASE_SENSITIVE
                                        styleID: TOOLBAR_BUTTON
                                        alignment: vcenter
                                    }
                                    Button {
                                        id: cbWholeWords
                                        checkable: true
                                        drawableID: "find_whole_words"
                                        tooltipText: EDIT_FIND_WHOLE_WORDS
                                        styleID: TOOLBAR_BUTTON
                                        alignment: vcenter
                                    }
                                    CheckBox { id: cbSelection; text: "Sel" }
                                }
                                VSpacer {}
                            }
                        }
                        Row {
                            id: replace
                            fillsWidth: true;
                            EditLine { id: edReplace; fillsWidth: true; alignment: vcenter }
                            Button { id: btnReplace; text: EDIT_REPLACE_NEXT }
                            Button { id: btnReplaceAndFind; text: EDIT_REPLACE_AND_FIND }
                            Button { id: btnReplaceAll; text: EDIT_REPLACE_ALL }
                        }
                    }
                    Column {
                        VSpacer {}
                        Button { id: btnClose; drawableID: close; styleID: BUTTON_TRANSPARENT }
                        VSpacer {}
                    }
                }
            }, null, this);
        }
        catch (Exception e)
        {
            Log.e("Exception while parsing DML: ", e);
        }
        _editor = editor;
        _edFind = childByID!EditLine("edFind");
        _edReplace = childByID!EditLine("edReplace");

        if (initialText.length)
        {
            _edFind.text = initialText;
            _edReplace.text = initialText;
        }
        debug (editors)
            Log.d("currentText=", _edFind.text);

        _edFind.enterKeyPressed.connect((EditWidgetBase e) {
            findNext(_backDirection);
            return true;
        });
        _edFind.contentChanged.connect(&onFindTextChange);

        _btnFindNext = childByID!Button("btnFindNext");
        _btnFindNext.clicked = &onButtonClick;
        _btnFindPrev = childByID!Button("btnFindPrev");
        _btnFindPrev.clicked = &onButtonClick;
        _btnReplace = childByID!Button("btnReplace");
        _btnReplace.clicked = &onButtonClick;
        _btnReplaceAndFind = childByID!Button("btnReplaceAndFind");
        _btnReplaceAndFind.clicked = &onButtonClick;
        _btnReplaceAll = childByID!Button("btnReplaceAll");
        _btnReplaceAll.clicked = &onButtonClick;
        _btnClose = childByID!Button("btnClose");
        _btnClose.clicked = &onButtonClick;
        _cbCaseSensitive = childByID!Button("cbCaseSensitive");
        _cbWholeWords = childByID!Button("cbWholeWords");
        _cbSelection = childByID!CheckBox("cbSelection");
        _cbCaseSensitive.checkChanged = &onCaseSensitiveCheckChange;
        _cbWholeWords.checkChanged = &onCaseSensitiveCheckChange;
        _cbSelection.checkChanged = &onCaseSensitiveCheckChange;
        focusGroup = true;
        if (!replace)
            childByID("replace").visibility = Visibility.gone;

        setDirection(false);
        updateHighlight();
    }

    void activate()
    {
        _edFind.setFocus();
        dstring currentText = _edFind.text;
        debug (editors)
            Log.d("activate.currentText=", currentText);
        _edFind.setCaretPos(0, cast(int)currentText.length, true);
    }

    bool onButtonClick(Widget source)
    {
        switch (source.id)
        {
        case "btnFindNext":
            findNext(false);
            return true;
        case "btnFindPrev":
            findNext(true);
            return true;
        case "btnClose":
            close();
            return true;
        case "btnReplace":
            replaceOne();
            return true;
        case "btnReplaceAndFind":
            replaceOne();
            findNext(_backDirection);
            return true;
        case "btnReplaceAll":
            replaceAll();
            return true;
        default:
            return true;
        }
    }

    void close()
    {
        _editor.setTextToHighlight(null, 0);
        _editor.closeFindPanel();
    }

    override bool onKeyEvent(KeyEvent event)
    {
        if (event.keyCode == KeyCode.tab)
            return super.onKeyEvent(event);
        if (event.action == KeyAction.keyDown && event.keyCode == KeyCode.escape)
        {
            close();
            return true;
        }
        return true;
    }

    protected bool _backDirection;
    void setDirection(bool back)
    {
        _backDirection = back;
        if (back)
        {
            _btnFindNext.resetState(State.default_);
            _btnFindPrev.setState(State.default_);
        }
        else
        {
            _btnFindNext.setState(State.default_);
            _btnFindPrev.resetState(State.default_);
        }
    }

    uint makeSearchFlags()
    {
        uint res = 0;
        if (_cbCaseSensitive.checked)
            res |= TextSearchFlag.caseSensitive;
        if (_cbWholeWords.checked)
            res |= TextSearchFlag.wholeWords;
        if (_cbSelection.checked)
            res |= TextSearchFlag.selectionOnly;
        return res;
    }

    bool findNext(bool back)
    {
        setDirection(back);
        dstring currentText = _edFind.text;
        debug (editors)
            Log.d("findNext text=", currentText, " back=", back);
        if (!currentText.length)
            return false;
        _editor.setTextToHighlight(currentText, makeSearchFlags);
        TextPosition pos = _editor.caretPos;
        bool res = _editor.findNextPattern(pos, currentText, makeSearchFlags, back ? -1 : 1);
        if (res)
        {
            _editor.selectionRange = TextRange(pos, TextPosition(pos.line, pos.pos + cast(int)currentText.length));
            _editor.ensureCaretVisible();
            //_editor.setCaretPos(pos.line, pos.pos, true);
        }
        return res;
    }

    bool replaceOne()
    {
        dstring currentText = _edFind.text;
        dstring newText = _edReplace.text;
        debug (editors)
            Log.d("replaceOne text=", currentText, " back=", _backDirection, " newText=", newText);
        if (!currentText.length)
            return false;
        _editor.setTextToHighlight(currentText, makeSearchFlags);
        TextPosition pos = _editor.caretPos;
        bool res = _editor.findNextPattern(pos, currentText, makeSearchFlags, 0);
        if (res)
        {
            _editor.selectionRange = TextRange(pos, TextPosition(pos.line, pos.pos + cast(int)currentText.length));
            _editor.replaceSelectionText(newText);
            _editor.selectionRange = TextRange(pos, TextPosition(pos.line, pos.pos + cast(int)newText.length));
            _editor.ensureCaretVisible();
            //_editor.setCaretPos(pos.line, pos.pos, true);
        }
        return res;
    }

    int replaceAll()
    {
        int count = 0;
        for (int i = 0;; i++)
        {
            debug (editors)
                Log.d("replaceAll - calling replaceOne, iteration ", i);
            if (!replaceOne())
                break;
            count++;
            TextPosition initialPosition = _editor.caretPos;
            debug (editors)
                Log.d("replaceAll - position is ", initialPosition);
            if (!findNext(_backDirection))
                break;
            TextPosition newPosition = _editor.caretPos;
            debug (editors)
                Log.d("replaceAll - next position is ", newPosition);
            if (_backDirection && newPosition >= initialPosition)
                break;
            if (!_backDirection && newPosition <= initialPosition)
                break;
        }
        debug (editors)
            Log.d("replaceAll - done, replace count = ", count);
        _editor.ensureCaretVisible();
        return count;
    }

    void updateHighlight()
    {
        dstring currentText = _edFind.text;
        debug (editors)
            Log.d("onFindTextChange.currentText=", currentText);
        _editor.setTextToHighlight(currentText, makeSearchFlags);
    }

    void onFindTextChange(EditableContent source)
    {
        debug (editors)
            Log.d("onFindTextChange");
        updateHighlight();
    }

    void onCaseSensitiveCheckChange(Widget source, bool checkValue)
    {
        updateHighlight();
    }
}