'use strict';

// ─────────────────────────────────────────────────────────────────
// Roblox Bridge — VS Code Extension  v1.3.0
// Hosts a local HTTP server so Roblox Studio can pull file changes
// and push edits back to disk.
//
// v1.3.0 Changelog:
//   • Output Channel — dedicated live log panel for all bridge activity
//   • TreeView — sidebar panel showing synced script hierarchy
//   • init.lua support — Rojo-compatible init.lua / init.server.lua / init.client.lua
//   • Two-way delete — Studio can delete files on disk via POST /delete-from-studio
//   • Auto-export on connect — optionally auto-rescan when Studio first connects
//   • Write-guard — debounce to prevent file watcher picking up bridge-written files
//   • New Roblox Script — right-click context menu to create scripts from templates
//   • Enhanced status bar — file count, last sync time, sync animation
//   • Improved toasts — action buttons on notifications (Show File, Dismiss)
//   • Deprecated API fixes — url.parse → new URL, catch blocks, body limit, graceful shutdown
// ─────────────────────────────────────────────────────────────────

const vscode = require('vscode');
const http   = require('http');
const fs     = require('fs');
const path   = require('path');
const os     = require('os');

// ── Constants ─────────────────────────────────────────────────────
const VERSION       = '1.3.0';
const MAX_BODY_SIZE = 10 * 1024 * 1024; // 10 MB

// ── State ─────────────────────────────────────────────────────────
let bridgeServer           = null;
let fileWatchers           = [];
let statusBarItem          = null;
let outputChannel          = null;  // Feature 3: dedicated output channel
let ignorePatterns         = [];
let currentPort            = 7777;
let serverStartTime        = 0;

// Connection tracking
let studioConnected        = false;
let lastHeartbeatTime      = 0;
let heartbeatCheckInterval = null;

// Stats
let pullCount              = 0;
let exportCount            = 0;
let lastPullNotifyTime     = 0;
let lastSyncTime           = 0;   // Feature 11: track last sync timestamp

// Write-guard (Feature 16): paths written by the bridge, debounced
const writeGuardPaths = new Set();
const WRITE_GUARD_MS  = 500;

// TreeView provider (Feature 9)
let treeDataProvider = null;

/**
 * pendingChanges  Map<relativePath, ChangeRecord>
 */
const pendingChanges = new Map();

// ── Output Channel (Feature 3) ───────────────────────────────────
function bridgeLog(msg) {
    const ts = new Date().toLocaleTimeString();
    const line = `[${ts}] ${msg}`;
    if (outputChannel) outputChannel.appendLine(line);
    console.log('[RobloxBridge]', msg);
}

function bridgeWarn(msg) {
    const ts = new Date().toLocaleTimeString();
    const line = `[${ts}] ⚠ ${msg}`;
    if (outputChannel) outputChannel.appendLine(line);
    console.warn('[RobloxBridge]', msg);
}

// ── TreeView Data Provider (Feature 9) ───────────────────────────
class RobloxTreeItem extends vscode.TreeItem {
    constructor(label, collapsibleState, contextValue, filePath, iconId) {
        super(label, collapsibleState);
        this.contextValue = contextValue || 'robloxItem';
        if (filePath) {
            this.resourceUri = vscode.Uri.file(filePath);
            this.command = {
                command: 'vscode.open',
                title: 'Open File',
                arguments: [vscode.Uri.file(filePath)]
            };
        }
        if (iconId) {
            this.iconPath = new vscode.ThemeIcon(iconId);
        }
    }
}

class RobloxBridgeTreeProvider {
    constructor() {
        this._onDidChangeTreeData = new vscode.EventEmitter();
        this.onDidChangeTreeData = this._onDidChangeTreeData.event;
    }

    refresh() {
        this._onDidChangeTreeData.fire();
    }

    getTreeItem(element) {
        return element;
    }

    getChildren(element) {
        if (!bridgeServer) {
            return [new RobloxTreeItem('Bridge not running — click to start', vscode.TreeItemCollapsibleState.None, 'startHint', null, 'plug')];
        }

        if (!element) {
            // Root level: group by Roblox service
            const services = new Map();
            for (const [, info] of pendingChanges) {
                if (info.event === 'delete' || !info.robloxPath) continue;
                const parts = info.robloxPath.split('/');
                const service = parts[0] || 'Unknown';
                if (!services.has(service)) services.set(service, []);
                services.get(service).push(info);
            }

            if (services.size === 0) {
                return [new RobloxTreeItem('No scripts synced yet', vscode.TreeItemCollapsibleState.None, 'empty', null, 'info')];
            }

            const items = [];
            for (const [service, scripts] of services) {
                const item = new RobloxTreeItem(
                    `${service} (${scripts.length})`,
                    vscode.TreeItemCollapsibleState.Collapsed,
                    'service',
                    null,
                    'folder'
                );
                item._serviceName = service;
                items.push(item);
            }
            return items;
        }

        // Children of a service: show scripts
        if (element._serviceName) {
            const items = [];
            for (const [relPath, info] of pendingChanges) {
                if (info.event === 'delete' || !info.robloxPath) continue;
                const parts = info.robloxPath.split('/');
                if (parts[0] !== element._serviceName) continue;

                const scriptName = parts[parts.length - 1];
                const iconId = info.scriptClass === 'Script' ? 'server-process'
                    : info.scriptClass === 'LocalScript' ? 'device-mobile'
                    : 'file-code';

                const absPath = resolveAbsPath(relPath);
                const item = new RobloxTreeItem(
                    `${scriptName}  (${info.scriptClass})`,
                    vscode.TreeItemCollapsibleState.None,
                    'script',
                    absPath,
                    iconId
                );
                item.tooltip = info.robloxPath;
                item.description = parts.slice(1, -1).join('/');
                items.push(item);
            }
            return items;
        }

        return [];
    }
}

function resolveAbsPath(relPath) {
    const folders = vscode.workspace.workspaceFolders;
    if (!folders?.length) return null;
    return path.join(folders[0].uri.fsPath, relPath);
}

// ── Activation ────────────────────────────────────────────────────
function activate(context) {
    // Feature 3: Create output channel
    outputChannel = vscode.window.createOutputChannel('Roblox Bridge');
    context.subscriptions.push(outputChannel);
    bridgeLog(`Roblox Bridge v${VERSION} activated`);

    statusBarItem = vscode.window.createStatusBarItem(
        vscode.StatusBarAlignment.Left, 100
    );
    setStatusBar('stopped');
    statusBarItem.show();
    context.subscriptions.push(statusBarItem);

    // Feature 9: TreeView
    treeDataProvider = new RobloxBridgeTreeProvider();
    const treeView = vscode.window.createTreeView('robloxBridgeExplorer', {
        treeDataProvider,
        showCollapseAll: true
    });
    context.subscriptions.push(treeView);

    context.subscriptions.push(
        vscode.commands.registerCommand('robloxBridge.start',      startBridge),
        vscode.commands.registerCommand('robloxBridge.stop',       stopBridge),
        vscode.commands.registerCommand('robloxBridge.rescan',     rescanWorkspace),
        vscode.commands.registerCommand('robloxBridge.showStatus', showBridgeStatus),
        vscode.commands.registerCommand('robloxBridge.newScript',  newRobloxScript),  // Feature 5
        vscode.commands.registerCommand('robloxBridge.showOutput', () => outputChannel.show())
    );

    const config = vscode.workspace.getConfiguration('robloxBridge');
    if (config.get('autoStart', false)) startBridge();
}

function deactivate() { stopBridge(); }

// ── Status bar (Feature 11: enhanced) ─────────────────────────────
function setStatusBar(state) {
    const fileCount = pendingChanges.size;
    const syncAgo   = lastSyncTime ? timeSince(lastSyncTime) : '';

    switch (state) {
        case 'connected':
            statusBarItem.text            = `$(broadcast) RB :${currentPort} $(check) ❙ ${fileCount} files` + (syncAgo ? ` ❙ ${syncAgo}` : '');
            statusBarItem.tooltip         = `Roblox Studio connected\n${fileCount} files tracked\nClick to stop`;
            statusBarItem.command         = 'robloxBridge.stop';
            statusBarItem.backgroundColor = undefined;
            break;
        case 'syncing':
            statusBarItem.text            = `$(sync~spin) RB :${currentPort} syncing…`;
            statusBarItem.tooltip         = 'Syncing with Studio…';
            statusBarItem.command         = 'robloxBridge.stop';
            statusBarItem.backgroundColor = undefined;
            break;
        case 'running':
            statusBarItem.text            = `$(broadcast) RB :${currentPort} ❙ ${fileCount} files`;
            statusBarItem.tooltip         = `Bridge running, waiting for Studio\n${fileCount} files tracked\nClick to stop`;
            statusBarItem.command         = 'robloxBridge.stop';
            statusBarItem.backgroundColor = new vscode.ThemeColor('statusBarItem.warningBackground');
            break;
        case 'stopped':
        default:
            statusBarItem.text            = '$(plug) Roblox Bridge';
            statusBarItem.tooltip         = 'Roblox Bridge is stopped — click to start';
            statusBarItem.command         = 'robloxBridge.start';
            statusBarItem.backgroundColor = undefined;
    }
}

function timeSince(ms) {
    const diff = Math.round((Date.now() - ms) / 1000);
    if (diff < 5)  return 'just now';
    if (diff < 60) return `${diff}s ago`;
    if (diff < 3600) return `${Math.round(diff / 60)}m ago`;
    return `${Math.round(diff / 3600)}h ago`;
}

// Periodically refresh status bar time display
let statusRefreshInterval = null;
function startStatusRefresh() {
    stopStatusRefresh();
    statusRefreshInterval = setInterval(() => {
        if (studioConnected) setStatusBar('connected');
        else if (bridgeServer) setStatusBar('running');
    }, 5000);
}
function stopStatusRefresh() {
    if (statusRefreshInterval) { clearInterval(statusRefreshInterval); statusRefreshInterval = null; }
}

// ── Heartbeat watcher ─────────────────────────────────────────────
function startHeartbeatWatcher() {
    stopHeartbeatWatcher();
    heartbeatCheckInterval = setInterval(() => {
        if (!studioConnected) return;
        const cfg       = vscode.workspace.getConfiguration('robloxBridge');
        const timeoutMs = (cfg.get('heartbeatTimeoutSeconds', 15)) * 1000;
        if (Date.now() - lastHeartbeatTime > timeoutMs) {
            studioConnected = false;
            setStatusBar('running');
            bridgeWarn('Studio disconnected (no heartbeat)');
            if (cfg.get('showConnectionNotifications', true)) {
                vscode.window.showWarningMessage(
                    'Roblox Bridge: Studio disconnected (no heartbeat).',
                    'Show Log'
                ).then(choice => {
                    if (choice === 'Show Log') outputChannel.show();
                });
            }
            if (treeDataProvider) treeDataProvider.refresh();
        }
    }, 3000);
}

function stopHeartbeatWatcher() {
    if (heartbeatCheckInterval) {
        clearInterval(heartbeatCheckInterval);
        heartbeatCheckInterval = null;
    }
}

// ── Server lifecycle ──────────────────────────────────────────────
function startBridge() {
    if (bridgeServer) {
        vscode.window.showInformationMessage('Roblox Bridge is already running.');
        return;
    }
    const config  = vscode.workspace.getConfiguration('robloxBridge');
    const port    = config.get('port', 7777);
    const src     = config.get('sourcePath', 'src');
    currentPort   = port;

    bridgeServer = http.createServer(requestHandler);

    bridgeServer.on('error', err => {
        const msg = err.code === 'EADDRINUSE'
            ? `Port ${port} is already in use — change robloxBridge.port in settings.`
            : `Roblox Bridge error: ${err.message}`;
        vscode.window.showErrorMessage(msg);
        bridgeLog(`Server error: ${err.message}`);
        bridgeServer = null;
        setStatusBar('stopped');
    });

    bridgeServer.listen(port, '127.0.0.1', () => {
        serverStartTime = Date.now();
        pullCount       = 0;
        exportCount     = 0;
        setStatusBar('running');
        bridgeLog(`Server started on port ${port}`);
        vscode.window.showInformationMessage(
            `Roblox Bridge running on port ${port}. Open Roblox Studio and click [Connect].`,
            'Show Log'
        ).then(choice => {
            if (choice === 'Show Log') outputChannel.show();
        });
        if (vscode.workspace.workspaceFolders?.length) {
            loadAllIgnorePatterns();
            setupFileWatchers(src);
            scanAllWorkspaces(src);
        }
        startHeartbeatWatcher();
        startStatusRefresh();
        if (treeDataProvider) treeDataProvider.refresh();
    });
}

function stopBridge() {
    stopHeartbeatWatcher();
    stopStatusRefresh();
    for (const w of fileWatchers) w.dispose();
    fileWatchers    = [];
    ignorePatterns  = [];
    studioConnected = false;

    if (bridgeServer) {
        // Fix 18: Graceful shutdown
        if (typeof bridgeServer.closeAllConnections === 'function') {
            bridgeServer.closeAllConnections();
        }
        bridgeServer.close();
        bridgeServer = null;
        pendingChanges.clear();
        setStatusBar('stopped');
        bridgeLog('Server stopped');
        vscode.window.showInformationMessage('Roblox Bridge stopped.');
        if (treeDataProvider) treeDataProvider.refresh();
    }
}

function rescanWorkspace() {
    if (!bridgeServer) {
        vscode.window.showWarningMessage('Start Roblox Bridge first.');
        return;
    }
    const src = vscode.workspace.getConfiguration('robloxBridge').get('sourcePath', 'src');
    pendingChanges.clear();
    loadAllIgnorePatterns();
    scanAllWorkspaces(src);
    bridgeLog(`Workspace rescanned — ${pendingChanges.size} file(s) found`);
    vscode.window.showInformationMessage(`Roblox Bridge: rescanned — ${pendingChanges.size} files.`);
    if (treeDataProvider) treeDataProvider.refresh();
}

function showBridgeStatus() {
    if (!bridgeServer) {
        vscode.window.showInformationMessage('Roblox Bridge is not running.');
        return;
    }
    const uptimeSec    = Math.round((Date.now() - serverStartTime) / 1000);
    const studioState  = studioConnected ? 'Studio connected' : 'Waiting for Studio';
    const lines = [
        `Port: ${currentPort}`,
        `Studio: ${studioState}`,
        `Pending files: ${pendingChanges.size}`,
        `Pulls: ${pullCount}  Exports: ${exportCount}`,
        `Uptime: ${uptimeSec}s`
    ];
    vscode.window.showInformationMessage('Roblox Bridge: ' + lines.join('  |  '), 'Show Log').then(choice => {
        if (choice === 'Show Log') outputChannel.show();
    });
}

// ── New Roblox Script (Feature 5) ─────────────────────────────────
async function newRobloxScript(uri) {
    const scriptType = await vscode.window.showQuickPick(
        [
            { label: '$(file-code) ModuleScript',    description: '.lua',            value: 'ModuleScript' },
            { label: '$(server-process) Script',     description: '.server.lua',     value: 'Script' },
            { label: '$(device-mobile) LocalScript', description: '.client.lua',     value: 'LocalScript' },
        ],
        { placeHolder: 'Select script type' }
    );
    if (!scriptType) return;

    const name = await vscode.window.showInputBox({
        prompt: 'Script name (without extension)',
        placeHolder: 'MyScript',
        validateInput: (v) => v && /^[a-zA-Z_][a-zA-Z0-9_]*$/.test(v) ? null : 'Invalid Lua identifier'
    });
    if (!name) return;

    const cfg = vscode.workspace.getConfiguration('robloxBridge');
    const preferLuau = cfg.get('preferLuau', false);
    const baseExt = preferLuau ? '.luau' : '.lua';

    let ext = baseExt;
    if (scriptType.value === 'Script')       ext = `.server${baseExt}`;
    if (scriptType.value === 'LocalScript')  ext = `.client${baseExt}`;

    const templates = {
        ModuleScript: `-- ${name}\n-- ModuleScript\n\nlocal ${name} = {}\n\nfunction ${name}.init()\n    -- TODO: implement\nend\n\nreturn ${name}\n`,
        Script:       `-- ${name}\n-- Server Script\n\nlocal Players = game:GetService("Players")\nlocal ReplicatedStorage = game:GetService("ReplicatedStorage")\n\nprint("[${name}] Server script started")\n`,
        LocalScript:  `-- ${name}\n-- Client Script\n\nlocal Players = game:GetService("Players")\nlocal player = Players.LocalPlayer\n\nprint("[${name}] Client script started")\n`,
    };

    let targetDir;
    if (uri && uri.fsPath) {
        const stat = fs.statSync(uri.fsPath);
        targetDir = stat.isDirectory() ? uri.fsPath : path.dirname(uri.fsPath);
    } else {
        const folders = vscode.workspace.workspaceFolders;
        if (!folders?.length) {
            vscode.window.showErrorMessage('No workspace folder open.');
            return;
        }
        targetDir = path.join(folders[0].uri.fsPath, cfg.get('sourcePath', 'src'));
    }

    const filePath = path.join(targetDir, name + ext);
    if (fs.existsSync(filePath)) {
        vscode.window.showWarningMessage(`File already exists: ${name}${ext}`);
        return;
    }

    fs.mkdirSync(targetDir, { recursive: true });
    fs.writeFileSync(filePath, templates[scriptType.value], 'utf8');
    const doc = await vscode.workspace.openTextDocument(filePath);
    await vscode.window.showTextDocument(doc);
    bridgeLog(`Created new ${scriptType.value}: ${filePath}`);
}

// ── .robloxignore support ─────────────────────────────────────────
function globToRegex(pattern) {
    const escaped = pattern
        .replace(/[.+^${}()|[\]\\]/g, '\\$&')
        .replace(/\*\*/g, '\x00')
        .replace(/\*/g,   '[^/]*')
        .replace(/\?/g,   '[^/]')
        .replace(/\x00/g, '.*');
    return new RegExp('^' + escaped + '$', 'i');
}

function loadAllIgnorePatterns() {
    ignorePatterns = [];
    for (const folder of (vscode.workspace.workspaceFolders || [])) {
        const f = path.join(folder.uri.fsPath, '.robloxignore');
        if (!fs.existsSync(f)) continue;
        try {
            const lines = fs.readFileSync(f, 'utf8')
                .split(/\r?\n/)
                .map(l => l.trim())
                .filter(l => l && !l.startsWith('#'));
            ignorePatterns.push(...lines);
        } catch (e) { bridgeWarn(`Failed to read .robloxignore: ${e.message}`); }
    }
}

function isIgnored(relPath) {
    for (const pattern of ignorePatterns) {
        const regex = globToRegex(pattern);
        if (!pattern.includes('/')) {
            const segments = relPath.split('/');
            if (segments.some(s => regex.test(s))) return true;
        } else {
            if (regex.test(relPath)) return true;
        }
    }
    return false;
}

// ── File watching ─────────────────────────────────────────────────
function setupFileWatchers(src) {
    for (const w of fileWatchers) w.dispose();
    fileWatchers = [];

    for (const folder of (vscode.workspace.workspaceFolders || [])) {
        const luaPattern = new vscode.RelativePattern(folder, `${src}/**/*.{lua,luau}`);
        const luaWatcher = vscode.workspace.createFileSystemWatcher(luaPattern);
        luaWatcher.onDidCreate(uri => recordChange(uri, 'create'));
        luaWatcher.onDidChange(uri => recordChange(uri, 'change'));
        luaWatcher.onDidDelete(uri => recordDelete(uri));
        fileWatchers.push(luaWatcher);

        const ignPattern = new vscode.RelativePattern(folder, '.robloxignore');
        const ignWatcher = vscode.workspace.createFileSystemWatcher(ignPattern);
        ignWatcher.onDidCreate(() => loadAllIgnorePatterns());
        ignWatcher.onDidChange(() => loadAllIgnorePatterns());
        ignWatcher.onDidDelete(() => loadAllIgnorePatterns());
        fileWatchers.push(ignWatcher);
    }
}

function recordChange(uri, event) {
    try {
        const rel = toRelative(uri.fsPath);
        if (!rel) return;
        if (isIgnored(rel)) return;

        // Feature 16: write-guard — skip if bridge just wrote this path
        if (writeGuardPaths.has(rel)) return;

        const content    = fs.readFileSync(uri.fsPath, 'utf8');
        const src        = vscode.workspace.getConfiguration('robloxBridge').get('sourcePath', 'src');
        const robloxInfo = toRobloxInfo(rel, src);

        pendingChanges.set(rel, {
            content,
            timestamp:   Date.now(),
            robloxPath:  robloxInfo.robloxPath,
            scriptClass: robloxInfo.scriptClass,
            event
        });
        if (treeDataProvider) treeDataProvider.refresh();
    } catch (e) { bridgeWarn(`recordChange error: ${e.message}`); }
}

function recordDelete(uri) {
    const rel = toRelative(uri.fsPath);
    if (!rel) return;
    if (isIgnored(rel)) return;
    pendingChanges.set(rel, { content: null, timestamp: Date.now(), event: 'delete' });
    if (treeDataProvider) treeDataProvider.refresh();
}

function scanAllWorkspaces(src) {
    for (const folder of (vscode.workspace.workspaceFolders || [])) {
        const dir = path.join(folder.uri.fsPath, src);
        if (!fs.existsSync(dir)) continue;
        scanDir(dir, folder.uri.fsPath, src);
    }
    bridgeLog(`Scanned workspace — ${pendingChanges.size} file(s) tracked`);
}

function scanDir(dir, root, src) {
    for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
        const full = path.join(dir, entry.name);
        const rel  = path.relative(root, full).replace(/\\/g, '/');
        if (isIgnored(rel)) continue;

        if (entry.isDirectory()) {
            scanDir(full, root, src);
        } else if (/\.lua[u]?$/.test(entry.name)) {
            const robloxInfo = toRobloxInfo(rel, src);
            pendingChanges.set(rel, {
                content:     fs.readFileSync(full, 'utf8'),
                timestamp:   Date.now(),
                robloxPath:  robloxInfo.robloxPath,
                scriptClass: robloxInfo.scriptClass,
                event:       'create'
            });
        }
    }
}

// ── Path helpers ──────────────────────────────────────────────────
function toRelative(fsPath) {
    for (const folder of (vscode.workspace.workspaceFolders || [])) {
        const root = folder.uri.fsPath;
        if (fsPath.startsWith(root + path.sep) || fsPath === root) {
            return path.relative(root, fsPath).replace(/\\/g, '/');
        }
    }
    return null;
}

function resolveWriteRoot(filePath) {
    const folders = vscode.workspace.workspaceFolders;
    if (!folders?.length) return getWorkspaceRoot();
    if (folders.length === 1) return folders[0].uri.fsPath;

    for (const folder of folders) {
        const abs = path.resolve(folder.uri.fsPath, filePath);
        if (abs.startsWith(folder.uri.fsPath + path.sep) && fs.existsSync(abs)) {
            return folder.uri.fsPath;
        }
    }
    return folders[0].uri.fsPath;
}

// Feature 7: init.lua / init.server.lua / init.client.lua support
function toRobloxInfo(relativePath, sourcePath) {
    let p = relativePath;
    const prefix = sourcePath.endsWith('/') ? sourcePath : sourcePath + '/';
    if (p.startsWith(prefix)) p = p.slice(prefix.length);

    let scriptClass = 'ModuleScript';
    let cleanPath   = p;

    // Check for init files first (Feature 7: Rojo-compatible)
    const basename = path.basename(p);
    if (/^init\.server\.lua[u]?$/.test(basename)) {
        scriptClass = 'Script';
        // init.server.lua → parent folder becomes the script
        cleanPath = path.dirname(p).replace(/\\/g, '/');
    } else if (/^init\.client\.lua[u]?$/.test(basename)) {
        scriptClass = 'LocalScript';
        cleanPath = path.dirname(p).replace(/\\/g, '/');
    } else if (/^init\.lua[u]?$/.test(basename)) {
        scriptClass = 'ModuleScript';
        cleanPath = path.dirname(p).replace(/\\/g, '/');
    } else if (/\.server\.lua[u]?$/.test(p)) {
        scriptClass = 'Script';
        cleanPath   = p.replace(/\.server\.lua[u]?$/, '');
    } else if (/\.client\.lua[u]?$/.test(p)) {
        scriptClass = 'LocalScript';
        cleanPath   = p.replace(/\.client\.lua[u]?$/, '');
    } else {
        cleanPath   = p.replace(/\.lua[u]?$/, '');
    }

    return { robloxPath: cleanPath, scriptClass };
}

// ── HTTP request handler ──────────────────────────────────────────
function requestHandler(req, res) {
    res.setHeader('Content-Type', 'application/json');
    res.setHeader('Access-Control-Allow-Origin', '*');
    res.setHeader('Access-Control-Allow-Methods', 'GET, POST, OPTIONS');
    res.setHeader('Access-Control-Allow-Headers', 'Content-Type');

    if (req.method === 'OPTIONS') { res.writeHead(200); res.end(); return; }

    const parsedUrl = new URL(req.url, `http://127.0.0.1:${currentPort}`);
    const pathname  = parsedUrl.pathname;

    // ── GET /  ── heartbeat ────────────────────────────────────────
    if (req.method === 'GET' && pathname === '/') {
        json(res, 200, { server: 'roblox-bridge', version: VERSION, status: 'ok' });
        return;
    }

    // ── GET /status  ── server stats ──────────────────────────────
    if (req.method === 'GET' && pathname === '/status') {
        json(res, 200, {
            server:           'roblox-bridge',
            version:          VERSION,
            studioConnected,
            lastHeartbeatTime,
            totalPulls:       pullCount,
            totalExports:     exportCount,
            pendingFileCount: pendingChanges.size,
            uptimeMs:         bridgeServer ? Date.now() - serverStartTime : 0
        });
        return;
    }

    // ── GET /config  ── settings for Roblox Studio plugin ─────────
    if (req.method === 'GET' && pathname === '/config') {
        const cfg = vscode.workspace.getConfiguration('robloxBridge');
        json(res, 200, {
            pollInterval:   cfg.get('pollInterval', 2),
            sourcePath:     cfg.get('sourcePath', 'src'),
            port:           cfg.get('port', 7777),
            preferLuau:     cfg.get('preferLuau', false),
            twoWayDelete:   cfg.get('twoWayDelete', false)
        });
        return;
    }

    // ── GET /changes?since=<timestamp> ────────────────────────────
    if (req.method === 'GET' && pathname === '/changes') {
        const since   = parseInt(parsedUrl.searchParams.get('since')) || 0;
        const changes = [];
        for (const [filePath, info] of pendingChanges) {
            if (info.timestamp > since) {
                changes.push({
                    path:        filePath,
                    robloxPath:  info.robloxPath  || null,
                    scriptClass: info.scriptClass || null,
                    event:       info.event,
                    timestamp:   info.timestamp,
                    content:     info.content
                });
            }
        }

        // Sync notification with action buttons (Feature 10)
        if (changes.length > 0) {
            pullCount++;
            lastSyncTime = Date.now();
            setStatusBar('connected');
            bridgeLog(`Studio pulled ${changes.length} change(s)`);

            const cfg = vscode.workspace.getConfiguration('robloxBridge');
            if (cfg.get('showSyncNotifications', false)) {
                const now = Date.now();
                if (now - lastPullNotifyTime > 5000) {
                    lastPullNotifyTime = now;
                    vscode.window.showInformationMessage(
                        `Roblox Bridge: Studio pulled ${changes.length} change(s).`,
                        'Show Log', 'Dismiss'
                    ).then(choice => {
                        if (choice === 'Show Log') outputChannel.show();
                    });
                }
            }
        }

        json(res, 200, { changes, serverTime: Date.now() });
        return;
    }

    // ── GET /files  ── full snapshot of tracked files ──────────────
    if (req.method === 'GET' && pathname === '/files') {
        const files = [];
        for (const [filePath, info] of pendingChanges) {
            if (info.event !== 'delete') {
                files.push({
                    path:        filePath,
                    robloxPath:  info.robloxPath,
                    scriptClass: info.scriptClass,
                    timestamp:   info.timestamp
                });
            }
        }
        json(res, 200, { files });
        return;
    }

    // ── POST /heartbeat  ── Studio announces it is alive ──────────
    if (req.method === 'POST' && pathname === '/heartbeat') {
        readBody(req, (err) => {
            if (err) { json(res, 400, { error: 'bad body' }); return; }

            const wasConnected  = studioConnected;
            studioConnected     = true;
            lastHeartbeatTime   = Date.now();

            if (!wasConnected) {
                setStatusBar('connected');
                bridgeLog(`Studio connected on port ${currentPort}`);

                const cfg = vscode.workspace.getConfiguration('robloxBridge');
                if (cfg.get('showConnectionNotifications', true)) {
                    vscode.window.showInformationMessage(
                        `Roblox Bridge: Studio connected on port ${currentPort}.`,
                        'Show Log'
                    ).then(choice => {
                        if (choice === 'Show Log') outputChannel.show();
                    });
                }

                // Feature 4: Auto-export on connect
                if (cfg.get('autoExportOnConnect', false)) {
                    bridgeLog('Auto-export triggered on first connect');
                    const src = cfg.get('sourcePath', 'src');
                    pendingChanges.clear();
                    loadAllIgnorePatterns();
                    scanAllWorkspaces(src);
                }

                if (treeDataProvider) treeDataProvider.refresh();
            }

            json(res, 200, { ok: true, serverTime: Date.now() });
        });
        return;
    }

    // ── POST /write  ── Roblox Studio writes a script back to disk ─
    if (req.method === 'POST' && pathname === '/write') {
        readBody(req, (err, body) => {
            if (err) { json(res, 400, { error: 'bad body' }); return; }

            let data;
            try { data = JSON.parse(body); } catch (e) {
                json(res, 400, { error: 'invalid JSON' }); return;
            }

            const { filePath, content, lastPulled, force } = data;
            if (!filePath || content === undefined) {
                json(res, 400, { error: 'filePath and content are required' }); return;
            }

            const root    = resolveWriteRoot(filePath);
            const absPath = path.resolve(root, filePath);

            if (!absPath.startsWith(root + path.sep) && absPath !== root) {
                json(res, 403, { error: 'path escapes workspace' }); return;
            }

            if (lastPulled !== undefined && !force && fs.existsSync(absPath)) {
                const stat = fs.statSync(absPath);
                if (stat.mtimeMs > lastPulled) {
                    bridgeWarn(`Conflict detected: ${filePath}`);
                    json(res, 200, {
                        success:      false,
                        conflict:     true,
                        diskModified: Math.round(stat.mtimeMs),
                        message:      'File was modified in VS Code after your last pull. ' +
                                      'Pull latest changes first, or upload with force=true to overwrite.'
                    });
                    return;
                }
            }

            try {
                fs.mkdirSync(path.dirname(absPath), { recursive: true });
                const tmpPath = absPath + '.rbtmp';
                fs.writeFileSync(tmpPath, content, 'utf8');
                fs.renameSync(tmpPath, absPath);

                // Feature 16: write-guard the path to prevent watcher loop
                const rel = toRelative(absPath);
                if (rel) {
                    writeGuardPaths.add(rel);
                    setTimeout(() => writeGuardPaths.delete(rel), WRITE_GUARD_MS);
                }

                bridgeLog(`Write from Studio: ${filePath}`);
                json(res, 200, { success: true });
            } catch (writeErr) {
                bridgeWarn(`Write failed: ${writeErr.message}`);
                json(res, 500, { error: writeErr.message });
            }
        });
        return;
    }

    // ── POST /delete-from-studio (Feature 6) ── Studio deletes a file on disk ─
    if (req.method === 'POST' && pathname === '/delete-from-studio') {
        readBody(req, (err, body) => {
            if (err) { json(res, 400, { error: 'bad body' }); return; }

            let data;
            try { data = JSON.parse(body); } catch (e) {
                json(res, 400, { error: 'invalid JSON' }); return;
            }

            const cfg = vscode.workspace.getConfiguration('robloxBridge');
            if (!cfg.get('twoWayDelete', false)) {
                json(res, 200, { success: false, reason: 'twoWayDelete is disabled in settings' });
                return;
            }

            const { robloxPath, scriptClass } = data;
            if (!robloxPath) {
                json(res, 400, { error: 'robloxPath is required' }); return;
            }

            // Find the matching file on disk
            const srcPath   = cfg.get('sourcePath', 'src');
            const preferLuau = cfg.get('preferLuau', false);
            const baseExt = preferLuau ? '.luau' : '.lua';

            let fileExt = baseExt;
            if (scriptClass === 'Script')        fileExt = `.server${baseExt}`;
            else if (scriptClass === 'LocalScript') fileExt = `.client${baseExt}`;

            const root    = getWorkspaceRoot();
            const absPath = path.join(root, srcPath, robloxPath.replace(/\//g, path.sep) + fileExt);

            if (fs.existsSync(absPath)) {
                try {
                    fs.unlinkSync(absPath);
                    const rel = path.relative(root, absPath).replace(/\\/g, '/');
                    pendingChanges.set(rel, { content: null, timestamp: Date.now(), event: 'delete' });
                    bridgeLog(`Deleted from Studio: ${absPath}`);
                    if (treeDataProvider) treeDataProvider.refresh();
                    json(res, 200, { success: true, deleted: absPath });
                } catch (e) {
                    bridgeWarn(`Delete failed: ${e.message}`);
                    json(res, 500, { error: e.message });
                }
            } else {
                // Try init.lua variants
                const initVariants = [
                    path.join(root, srcPath, robloxPath.replace(/\//g, path.sep), `init${baseExt}`),
                    path.join(root, srcPath, robloxPath.replace(/\//g, path.sep), `init.server${baseExt}`),
                    path.join(root, srcPath, robloxPath.replace(/\//g, path.sep), `init.client${baseExt}`),
                ];
                let deleted = false;
                for (const variant of initVariants) {
                    if (fs.existsSync(variant)) {
                        fs.unlinkSync(variant);
                        bridgeLog(`Deleted (init variant) from Studio: ${variant}`);
                        deleted = true;
                        break;
                    }
                }
                json(res, 200, { success: deleted, message: deleted ? 'deleted init variant' : 'file not found' });
            }
        });
        return;
    }

    // ── POST /sync-from-studio  ── Studio exports its whole script tree ─
    if (req.method === 'POST' && pathname === '/sync-from-studio') {
        readBody(req, (err, body) => {
            if (err) { json(res, 400, { error: 'bad body' }); return; }

            let data;
            try { data = JSON.parse(body); } catch (e) {
                json(res, 400, { error: 'invalid JSON' }); return;
            }

            const scripts = data.scripts;
            if (!Array.isArray(scripts) || scripts.length === 0) {
                json(res, 400, { error: 'scripts array is required and must not be empty' });
                return;
            }

            setStatusBar('syncing');

            const config     = vscode.workspace.getConfiguration('robloxBridge');
            const srcPath    = config.get('sourcePath', 'src');
            const preferLuau = config.get('preferLuau', false);
            const baseExt    = preferLuau ? '.luau' : '.lua';
            const root       = getWorkspaceRoot();
            const srcDir     = path.join(root, srcPath);

            let created = 0;
            let updated = 0;

            for (const script of scripts) {
                const { robloxPath, scriptClass, content } = script;
                if (!robloxPath || content === undefined) continue;

                let fileExt = baseExt;
                if (scriptClass === 'Script')           fileExt = `.server${baseExt}`;
                else if (scriptClass === 'LocalScript') fileExt = `.client${baseExt}`;

                const absPath = path.join(srcDir, robloxPath.replace(/\//g, path.sep) + fileExt);

                try {
                    fs.mkdirSync(path.dirname(absPath), { recursive: true });
                    const exists = fs.existsSync(absPath);
                    fs.writeFileSync(absPath, content, 'utf8');

                    const rel        = path.relative(root, absPath).replace(/\\/g, '/');
                    const robloxInfo = toRobloxInfo(rel, srcPath);

                    // Feature 16: write-guard
                    writeGuardPaths.add(rel);
                    setTimeout(() => writeGuardPaths.delete(rel), WRITE_GUARD_MS);

                    pendingChanges.set(rel, {
                        content,
                        timestamp:   Date.now() - 5000,
                        robloxPath:  robloxInfo.robloxPath,
                        scriptClass: robloxInfo.scriptClass,
                        event:       'create'
                    });

                    exists ? updated++ : created++;
                } catch (e) { bridgeWarn(`Export write error: ${e.message}`); }
            }

            exportCount++;
            lastSyncTime = Date.now();
            json(res, 200, { success: true, created, updated, path: root });

            const total = created + updated;
            bridgeLog(`Export complete: ${created} new, ${updated} updated (${total} total)`);

            const cfg   = vscode.workspace.getConfiguration('robloxBridge');
            if (cfg.get('showSyncNotifications', false)) {
                vscode.window.showInformationMessage(
                    `Roblox Bridge: export complete — ${created} new, ${updated} updated (${total} total)`,
                    'Open Folder', 'Show Log'
                ).then(choice => {
                    if (choice === 'Open Folder') {
                        vscode.commands.executeCommand('revealFileInOS', vscode.Uri.file(srcDir));
                    } else if (choice === 'Show Log') {
                        outputChannel.show();
                    }
                });
            } else {
                vscode.window.showInformationMessage(
                    `Roblox Bridge: exported ${total} script(s) from Studio.`
                );
            }

            if (!vscode.workspace.workspaceFolders?.length) {
                vscode.commands.executeCommand('vscode.openFolder', vscode.Uri.file(root), false);
            } else {
                const src2 = vscode.workspace.getConfiguration('robloxBridge').get('sourcePath', 'src');
                for (const w of fileWatchers) w.dispose();
                fileWatchers = [];
                setupFileWatchers(src2);
            }

            setStatusBar(studioConnected ? 'connected' : 'running');
            if (treeDataProvider) treeDataProvider.refresh();
        });
        return;
    }

    json(res, 404, { error: 'not found' });
}

// ── Workspace root helper ─────────────────────────────────────────
function getWorkspaceRoot() {
    if (vscode.workspace.workspaceFolders?.length) {
        return vscode.workspace.workspaceFolders[0].uri.fsPath;
    }
    const fallback = path.join(os.homedir(), 'RobloxBridge');
    fs.mkdirSync(fallback, { recursive: true });
    return fallback;
}

function json(res, code, data) {
    res.writeHead(code);
    res.end(JSON.stringify(data));
}

function readBody(req, cb) {
    let body = '';
    let size = 0;
    req.on('data', chunk => {
        size += chunk.length;
        if (size > MAX_BODY_SIZE) {
            req.destroy();
            cb(new Error('Body too large (max 10 MB)'));
            return;
        }
        body += chunk.toString();
    });
    req.on('end',   ()  => cb(null, body));
    req.on('error', err => cb(err));
}

module.exports = { activate, deactivate };
