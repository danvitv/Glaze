import { syncProvider, syncStatus, SYNC_STATUS, setSyncProgress, clearSyncProgress, setSyncError, updateLastSyncTime, addConflict, clearConflicts, resetMessageCounter, PROVIDERS } from '@/core/states/syncState.js';
import { publishAppEvent } from '@/core/events/eventHub.js';
import { APP_EVENTS } from '@/core/events/eventNames.js';
import * as dropboxAdapter from '@/core/services/adapters/dropboxAdapter.js';
import * as gdriveAdapter from '@/core/services/adapters/gdriveAdapter.js';
import { pushEntities, pullEntities, detectEncryptionState, isEncryptionEnabled } from '@/core/services/syncEngine.js';
import { flushLorebookSave } from '@/core/states/lorebookState.js';
import { getSyncKey, hasSyncKey } from '@/core/services/crypto/keyManager.js';
import { ref } from 'vue';

const isDbReady = ref(false);
export { isDbReady };

function getAdapter() {
    if (syncProvider.value === PROVIDERS.DROPBOX) return dropboxAdapter;
    if (syncProvider.value === PROVIDERS.GDRIVE) return gdriveAdapter;
    throw new Error('No sync provider connected');
}

export async function fullPush() {
    if (!isDbReady.value) return;
    if (syncStatus.value === SYNC_STATUS.SYNCING) return;

    syncStatus.value = SYNC_STATUS.SYNCING;
    clearConflicts();
    clearSyncProgress();

    try {
        const adapter = getAdapter();
        await detectEncryptionState();
        const encryptionEnabled = isEncryptionEnabled();
        const key = encryptionEnabled ? await getSyncKey() : null;
        if (encryptionEnabled && !key) throw new Error('Failed to load sync key');

        await adapter.ensureFolder('/Glaze');
        await adapter.ensureFolder('/Glaze/characters');
        await adapter.ensureFolder('/Glaze/personas');
        await adapter.ensureFolder('/Glaze/chats');

        await flushLorebookSave();

        const result = await pushEntities(adapter, key, (phase, current, total) => {
            setSyncProgress(phase, current, total);
        });

        updateLastSyncTime();
        resetMessageCounter();
        syncStatus.value = SYNC_STATUS.IDLE;
        clearSyncProgress();
        return result;
    } catch (e) {
        setSyncError(e.message);
        throw e;
    }
}

export async function fullPull() {
    if (!isDbReady.value) return;
    if (syncStatus.value === SYNC_STATUS.SYNCING) return;

    syncStatus.value = SYNC_STATUS.SYNCING;
    clearConflicts();
    clearSyncProgress();

    try {
        const adapter = getAdapter();
        await detectEncryptionState();
        const key = isEncryptionEnabled() ? await getSyncKey() : null;
        if (isEncryptionEnabled() && !key) throw new Error('Failed to load sync key');

        const result = await pullEntities(
            adapter,
            key,
            (phase, current, total) => {
                setSyncProgress(phase, current, total);
            },
            (conflict) => {
                addConflict(conflict);
            }
        );

        if (result.conflicts.length > 0) {
            syncStatus.value = SYNC_STATUS.CONFLICT;
        } else {
            updateLastSyncTime();
            resetMessageCounter();
            syncStatus.value = SYNC_STATUS.IDLE;
        }
        clearSyncProgress();
        publishAppEvent(APP_EVENTS.domain.sync.dataRefreshed, result);
        return result;
    } catch (e) {
        setSyncError(e.message);
        throw e;
    }
}

export async function fullSync() {
    await fullPush();
    await fullPull();
}

export async function checkSyncReadiness() {
    if (!isDbReady.value) return { ready: false, reason: 'db_not_ready' };
    if (!syncProvider.value) return { ready: false, reason: 'no_provider' };
    return { ready: true };
}
