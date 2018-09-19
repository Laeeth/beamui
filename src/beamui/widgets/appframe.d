/**
This module contains definition for main widget for usual application - with menu and status bar.

When you need MenuBar, StatusBar, Toolbars in your app, reuse this class.

Synopsis:
---
import beamui.widgets.appframe;
---

Copyright: Vadim Lopatin 2015
License:   Boost License 1.0
Authors:   Vadim Lopatin
*/
module beamui.widgets.appframe;

import std.path;
import beamui.core.files;
import beamui.core.settings;
import beamui.widgets.layouts;
import beamui.widgets.menu;
import beamui.widgets.statusline;
import beamui.widgets.toolbars;
import beamui.widgets.widget;

/// To update status for background operation in AppFrame
class BackgroundOperationWatcher
{
    protected
    {
        AppFrame _frame;
        bool _cancelRequested;
        bool _finished;
    }

    this(AppFrame frame)
    {
        _frame = frame;
    }

    /// Returns cancel status
    @property bool cancelRequested()
    {
        return _cancelRequested;
    }
    /// Returns description of background operation to show in status line
    @property dstring description()
    {
        return null;
    }
    /// Returns icon of background operation to show in status line
    @property string icon()
    {
        return null;
    }
    /// Returns desired update interval
    @property long updateInterval()
    {
        return 100;
    }
    /// Update background operation status
    void update()
    {
        // do some work here
        // when task is done or cancelled, finished should return true
        // either simple update of status or some real work can be done here
        if (_frame.statusLine)
            _frame.statusLine.setBackgroundOperationStatus(icon, description);
    }
    /// Request cancel - once cancelled, finished should return true
    void cancel()
    {
        _cancelRequested = true;
    }
    /// Returns true when task is done - to remove it from AppFrame
    @property bool finished()
    {
        return _finished;
    }
    /// Will be called by app frame when BackgroundOperationWatcher is to be removed
    void removing()
    {
        // in this handler, you can post new background operation to AppFrame
        if (_frame.statusLine)
            _frame.statusLine.setBackgroundOperationStatus(null, null);
    }
}

/// Base class for application frame with main menu, status line, toolbars
class AppFrame : Column
{
    @property
    {
        /// Main menu widget
        MenuBar mainMenu()
        {
            return _mainMenu;
        }
        /// Status line widget
        StatusLine statusLine()
        {
            return _statusLine;
        }
        /// Tool bar host
        ToolBarHost toolbars()
        {
            return _toolbarHost;
        }
        /// Body widget
        Widget frameBody()
        {
            return _body;
        }

        /// Override to return some identifier for app, e.g. to use as settings directory name
        string appCodeName() const
        {
            return _appName;
        }
        /// Override to return some identifier for app, e.g. to use as settings directory name
        AppFrame appCodeName(string name)
        {
            _appName = name;
            return this;
        }

        /// Application settings directory; by default, returns .appcodename directory in user's home directory (e.g. /home/user/.appcodename, C:\Users\User\AppData\Roaming\.appcodename); override to change it
        string settingsDir()
        {
            if (!_settingsDir)
                _settingsDir = appDataPath("." ~ appCodeName);
            return _settingsDir;
        }

        /// Returns shortcuts settings object
        SettingsFile shortcutSettings()
        {
            if (!_shortcutSettings)
                _shortcutSettings = new SettingsFile(buildNormalizedPath(settingsDir, "shortcuts.json"));
            return _shortcutSettings;
        }
    }

    protected
    {
        MenuBar _mainMenu;
        StatusLine _statusLine;
        ToolBarHost _toolbarHost;
        Widget _body;
        BackgroundOperationWatcher _currentBackgroundOperation;
        ulong _currentBackgroundOperationTimer;

        string _appName;
        string _settingsDir;
        SettingsFile _shortcutSettings;
    }

    this()
    {
        _appName = "beamui";
        initialize();
    }

    bool applyShortcutsSettings()
    {
        if (shortcutSettings.loaded)
        {
            foreach (key, value; _shortcutSettings.map)
            {
                Action action = Action.findByName(key);
                if (!action)
                {
                    Log.e("applyShortcutsSettings: Unknown action name: ", key);
                }
                else
                {
                    Shortcut[] shortcuts;
                    if (value.isArray)
                    {
                        foreach (i; 0 .. value.length)
                        {
                            string v = value[i].str;
                            Shortcut s;
                            if (s.parse(v))
                                shortcuts ~= s;
                            else
                                Log.e("applyShortcutsSettings: cannot parse accelerator: ", v);
                        }
                    }
                    else
                    {
                        string v = value.str;
                        Shortcut s;
                        if (s.parse(v))
                            shortcuts ~= s;
                        else
                            Log.e("applyShortcutsSettings: cannot parse accelerator: ", v);
                    }
                    action.shortcuts = shortcuts;
                }
            }
            return true;
        }
        return false;
    }

    /// Set shortcut settings from actions and save to file - useful for initial settings file version creation
    bool saveShortcutsSettings(const(Action)[] actions)
    {
        shortcutSettings.clear();
        foreach (a; actions)
        {
            string name = a.id;
            if (name)
            {
                auto shortcuts = a.shortcuts;
                if (shortcuts.length == 1)
                    _shortcutSettings[name] = shortcuts[0].toString;
                else if (shortcuts.length > 1)
                    _shortcutSettings[name] = shortcuts.emap!(a => a.toString);
            }
        }
        return shortcutSettings.save();
    }

    /// Timer handler
    override bool onTimer(ulong timerID)
    {
        if (timerID == _currentBackgroundOperationTimer)
        {
            if (_currentBackgroundOperation)
            {
                _currentBackgroundOperation.update();
                if (_currentBackgroundOperation.finished)
                {
                    _currentBackgroundOperation.removing();
                    destroy(_currentBackgroundOperation);
                    _currentBackgroundOperation = null;
                    _currentBackgroundOperationTimer = 0;
                    requestActionsUpdate();
                    return false;
                }
                return true;
            }
            else
            {
                _currentBackgroundOperationTimer = 0;
            }
        }
        return false; // stop timer
    }

    /// Set background operation to show in status
    void setBackgroundOperation(BackgroundOperationWatcher op)
    {
        if (_currentBackgroundOperation)
        {
            _currentBackgroundOperation.removing();
            destroy(_currentBackgroundOperation);
            _currentBackgroundOperation = null;
        }
        _currentBackgroundOperation = op;
        if (op)
            _currentBackgroundOperationTimer = setTimer(op.updateInterval);
        requestActionsUpdate();
    }

    protected void initialize()
    {
        _mainMenu = createMainMenu();
        _toolbarHost = createToolbars();
        _statusLine = createStatusLine();
        _body = createBody();
        _body.focusGroup = true;
        if (_mainMenu)
        {
            _mainMenu.menuItemClicked = &onMenuItemClick;
            addChild(_mainMenu);
        }
        if (_toolbarHost)
            addChild(_toolbarHost);
        addChild(_body);
        if (_statusLine)
            addChild(_statusLine);
        updateShortcuts();
    }

    /// Override it
    protected void updateShortcuts()
    {
    }

    /// Override if you want extra handling for main menu commands
    protected void onMenuItemClick(MenuItem item)
    {
    }

    /// Create main menu
    protected MenuBar createMainMenu()
    {
        return new MenuBar;
    }

    /// Create app toolbars
    protected ToolBarHost createToolbars()
    {
        auto res = new ToolBarHost;
        return res;
    }

    /// Create app status line widget
    protected StatusLine createStatusLine()
    {
        return new StatusLine;
    }

    /// Create app body widget
    protected Widget createBody()
    {
        Widget res = new Widget("APP_FRAME_BODY");
        res.fillWH();
        return res;
    }
}