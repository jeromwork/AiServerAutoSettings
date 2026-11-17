// Use Happier's own credential/encryption/CAS implementation. No private values
// or upstream exceptions may reach stdout, stderr or our configuration files.
const fs = require('node:fs');
const path = require('node:path');
const {pathToFileURL} = require('node:url');

function settingsPatch(settings, policy) {
    const mode = policy.defaultPermissionMode;
    const defaults = {...settings.sessionDefaultPermissionModeByTargetKey};
    for (const agent of ['claude', 'codex', 'gemini', 'agy']) defaults[`agent:${agent}`] = mode;
    for (const key of Object.keys(defaults)) defaults[key] = mode;
    const profiles = (settings.profiles || []).map(profile => ({...profile,
        defaultPermissionMode: mode,
        defaultPermissionModeByTargetKey: Object.fromEntries(Object.keys(profile.defaultPermissionModeByTargetKey || {}).map(key => [key, mode]))}));
    return {...settings, sessionDefaultPermissionModeByTargetKey: defaults, profiles,
        featureToggles: {...settings.featureToggles, connectedServices: true},
        connectedServicesProfileLabelByKey: {...settings.connectedServicesProfileLabelByKey,
            ...Object.fromEntries(Object.entries(policy.claudeAccountLabels).map(([id, label]) => [`claude-subscription/${id}`, label]))}};
}

async function main() {
    const policy = JSON.parse(fs.readFileSync(0, 'utf8'));
    const home = process.env.HAPPIER_HOME || path.join(require('node:os').homedir(), '.happier');
    const dist = path.join(fs.realpathSync(path.join(home, 'cli/current')), 'package-dist');
    async function exported(prefix, name) {
        const file = fs.readdirSync(dist).find(n => n.startsWith(prefix + '-') && n.endsWith('.mjs'));
        if (!file) throw Error();
        const source = fs.readFileSync(path.join(dist, file), 'utf8');
        const exportBlock = source.slice(source.lastIndexOf('export {'));
        const alias = exportBlock.match(new RegExp(`\\b${name} as (\\w+)\\b`))?.[1];
        if (!alias) throw Error();
        return (await import(pathToFileURL(path.join(dist, file)).href))[alias];
    }
    const readCredentials = await exported('persistence', 'readCredentials');
    const update = await exported('updateAccountSettingsV2WithRetry', 'updateAccountSettingsV2WithRetry');
    const credentials = await readCredentials();
    if (!credentials) throw Error();
    await update({credentials, mutate: settings => settingsPatch(settings, policy)});
    process.stdout.write('Happier account defaults reconciled\n');
}
module.exports = {settingsPatch};
if (require.main === module) {
    // Vendor diagnostics can contain request details: suppress them completely.
    for (const name of ['log', 'warn', 'error', 'debug', 'info']) console[name] = () => {};
    main().catch(() => {process.stderr.write('Happier account defaults unavailable\n'); process.exitCode = 1;});
}
