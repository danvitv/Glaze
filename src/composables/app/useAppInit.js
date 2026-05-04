import { onMounted, onBeforeUnmount } from 'vue';
import { Capacitor } from '@capacitor/core';
import { initSettings, applyApiRuntimeConfig } from '@/core/config/APISettings.js';
import { initTheme } from '@/core/states/themeState.js';
import { loadPersonas } from '@/core/states/personaState.js';
import { initLorebookState } from '@/core/states/lorebookState.js';
import { initPresetState } from '@/core/states/presetState.js';
import { initSyncState, syncProvider } from '@/core/states/syncState.js';
import { checkSyncReadiness, fullPull, isDbReady } from '@/core/services/syncService.js';
import { startTracking } from '@/core/services/timeTracker.js';
import { initThemeToggle, initHeaderDropdown, initViewportFix } from '@/core/services/ui.js';
import { initRipple } from '@/core/services/interactionEffects.js';
import { checkAndRequestNotifications, consumePendingNotificationData } from '@/core/services/notificationService.js';
import { generateMissingThumbnails } from '@/utils/characterIO.js';
import { migrateScToGz, db } from '@/utils/db.js';
import { seedDefaultCharacters } from '@/utils/seedDefaultCharacters.js';
import { isKeyboardOpen, onKeyboardShow, onKeyboardHide } from '@/core/services/keyboardHandler.js';
import { updateLanguage } from '@/utils/i18n.js';
import { publishAppEvent } from '@/core/events/eventHub.js';
import { APP_EVENTS } from '@/core/events/eventNames.js';

export function useAppInit({
    isOnboarding,
    isDataLoaded,
    isDesktop,
    checkDesktop,
    updateLayoutMetrics,
    initBackButton,
    headerContainer,
    footerContainer,
    categories,
    activeCategories,
    appEventUnsubs,
    handleOpenChatEvent
}) {
    let layoutObserver = null;
    const kbListeners = [];
    let lastVisibilityHidden = 0;

    async function onVisibilityChange() {
        if (document.visibilityState === 'hidden') {
            lastVisibilityHidden = Date.now();
            return;
        }
        const wasHiddenMs = Date.now() - lastVisibilityHidden;
        if (wasHiddenMs < 5000) return;
        if (!isDbReady.value) return;

        const skipPull = localStorage.getItem('gz_skip_sync_pull');
        if (skipPull) {
            localStorage.removeItem('gz_skip_sync_pull');
            publishAppEvent(APP_EVENTS.domain.sync.dataRefreshed, {});
            return;
        }

        try {
            const chars = await db.getAll('characters');
            if (chars?.length > 0) {
                publishAppEvent(APP_EVENTS.domain.sync.dataRefreshed, {});
                return;
            }
        } catch { }

        if (syncProvider.value) {
            try {
                await fullPull();
            } catch (e) {
                console.warn('[App] Auto-pull after wake failed:', e);
            }
        } else {
            console.warn('[App] IndexedDB appears empty after wake and no cloud provider configured');
        }
    }

    onMounted(async () => {
        await migrateScToGz();
        await seedDefaultCharacters();

        isOnboarding.value = localStorage.getItem('glaze_onboarding_completed') !== 'true';

        initSettings();
        await initTheme();
        await Promise.all([
            initLorebookState(),
            initPresetState(),
            loadPersonas(),
            initSyncState()
        ]);

        startTracking();

        if (syncProvider.value) {
            const skipPull = localStorage.getItem('gz_skip_sync_pull');
            if (skipPull) {
                localStorage.removeItem('gz_skip_sync_pull');
            } else {
                checkSyncReadiness().then(ready => {
                    if (ready.ready) {
                        fullPull().catch(e => console.warn('[App] Background pull failed:', e));
                    }
                });
            }
        }

        initRipple();
        initThemeToggle();
        initViewportFix();
        initBackButton();

        initHeaderDropdown(categories, activeCategories, () => { });

        const pendingData = consumePendingNotificationData();
        if (pendingData) {
            handleOpenChatEvent(pendingData);
        }

        layoutObserver = new ResizeObserver(() => {
            requestAnimationFrame(updateLayoutMetrics);
        });
        if (headerContainer.value) layoutObserver.observe(headerContainer.value);
        if (footerContainer.value) layoutObserver.observe(footerContainer.value);
        updateLayoutMetrics();

        updateLanguage();
        isDataLoaded.value = true;
        isDbReady.value = true;

        generateMissingThumbnails();

        checkDesktop();
        window.addEventListener('resize', checkDesktop);
        document.addEventListener('visibilitychange', onVisibilityChange);

        setTimeout(() => {
            document.body.classList.remove('preload');
            document.body.classList.add('app-loaded');
        }, 100);

        setTimeout(checkAndRequestNotifications, 1000);

        if (Capacitor.isNativePlatform()) {
            kbListeners.push(await onKeyboardShow(() => { isKeyboardOpen.value = true; }));
            kbListeners.push(await onKeyboardHide(() => { isKeyboardOpen.value = false; }));
        }
    });

    onBeforeUnmount(() => {
        if (layoutObserver) layoutObserver.disconnect();
        appEventUnsubs.forEach(unsub => unsub());
        appEventUnsubs.length = 0;
        kbListeners.forEach(l => l.remove());
        window.removeEventListener('resize', checkDesktop);
        document.removeEventListener('visibilitychange', onVisibilityChange);
    });

    return { kbListeners };
}
