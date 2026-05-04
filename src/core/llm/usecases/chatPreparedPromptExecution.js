import { runPreparedChatPrompt } from '@/core/llm/usecases/chatPreparation.js';
import { Capacitor } from '@capacitor/core';
import { Share } from '@capacitor/share';

function copyDiagnosticText(text) {
    if (Capacitor.isNativePlatform()) {
        Share.share({ text });
        return;
    }
    if (navigator.clipboard?.writeText) {
        navigator.clipboard.writeText(text).catch(() => {
            fallbackCopyText(text);
        });
        return;
    }
    fallbackCopyText(text);
}

function fallbackCopyText(text) {
    const ta = document.createElement('textarea');
    ta.value = text;
    ta.style.cssText = 'position:fixed;left:-9999px;top:-9999px;opacity:0';
    document.body.appendChild(ta);
    ta.select();
    try { document.execCommand('copy'); } catch (_) {}
    document.body.removeChild(ta);
}

export async function executePreparedChatPrompt({
    preparedRequest,
    onError,
    deps
}) {
    const {
        t,
        showBottomSheet,
        closeBottomSheet,
        openApiSheet
    } = deps;
    const {
        apiConfig,
        tagStart,
        tagEnd,
        stopString,
        requestReasoning,
        reasoningEffort,
        maxTokens,
        contextSize,
        varsKey,
        safeHistory,
        controller
    } = preparedRequest;
    const {
        providerId,
        apiKey,
        apiUrl,
        model,
        stream,
        temp,
        topP,
        omitTemperature,
        omitTopP,
        omitReasoning,
        omitReasoningEffort
    } = apiConfig;

    if (!apiUrl || !model) {
        showBottomSheet({
            title: t('section_connection') || 'Connection',
            bigInfo: {
                icon: '<svg viewBox="0 0 24 24" style="fill:currentColor;width:100%;height:100%;"><path d="M19.14 12.94c.04-.3.06-.61.06-.94 0-.32-.02-.64-.07-.94l2.03-1.58c.18-.14.23-.41.12-.61l-1.92-3.32c-.12-.22-.37-.29-.59-.22l-2.39.96c-.5-.38-1.03-.7-1.62-.94l-.36-2.54c-.04-.24-.24-.41-.48-.41h-3.84c-.24 0-.43.17-.47.41l-.36 2.54c-.59.24-1.13.57-1.62.94l-2.39-.96c-.22-.08-.47 0-.59.22L2.74 8.87c-.12.21-.08.47.12.61l2.03 1.58c-.05.3-.09.63-.09.94s.02.64.07.94l-2.03 1.58c-.18.14-.23.41-.12.61l1.92 3.32c.12.22.37.29.59.22l2.39-.96c.5.38 1.03.7 1.62.94l.36 2.54c.04.24.24.41.48.41h3.84c.24 0 .43-.17.47-.41l.36-2.54c.59-.24 1.13-.57 1.62-.94l2.39.96c.22.08.47 0 .59-.22l1.92-3.32c.12-.22.07-.47-.12-.61l-2.01-1.58zM12 15.6c-1.98 0-3.6-1.62-3.6-3.6s1.62-3.6 3.6-3.6 3.6 1.62 3.6 3.6-1.62 3.6-3.6 3.6z"/></svg>',
                description: t('api_not_configured') || 'API Not Configured',
                buttonText: t('btn_configure') || 'Configure',
                onButtonClick: () => {
                    closeBottomSheet();
                    openApiSheet();
                }
            }
        });
        if (onError) onError(new Error('API Not Configured'));
        return null;
    }

    let result;
    try {
        ({ result } = await runPreparedChatPrompt(preparedRequest));
    } catch (e) {
        console.error('Worker error:', e);
        if (e.message?.includes('Prompt building timed out') && e._diagnostic) {
            showBottomSheet({
                title: t('prompt_timeout_title') || 'Prompt Timeout',
                bigInfo: {
                    icon: '<svg viewBox="0 0 24 24" style="fill:currentColor;width:100%;height:100%;"><path d="M12 2C6.48 2 2 6.48 2 12s4.48 10 10 10 10-4.48 10-10S17.52 2 12 2zm1 15h-2v-2h2v2zm0-4h-2V7h2v6z"/></svg>',
                    description: e._diagnostic,
                    buttonText: t('btn_copy') || 'Copy',
                    onButtonClick: () => {
                        copyDiagnosticText(e._diagnostic);
                    }
                }
            });
        }
        if (onError) onError(e);
        return null;
    }

    if (controller?.signal?.aborted) {
        if (onError) {
            const abortErr = new DOMException('Aborted', 'AbortError');
            if (controller?.userAborted) {
                abortErr.userAborted = true;
            }
            onError(abortErr);
        }
        return null;
    }

    if (result.needsVarsSave) {
        localStorage.setItem(varsKey, JSON.stringify(result.sessionVars));
    }

    return {
        result,
        safeHistory,
        contextSize,
        maxTokens,
        memoryReserve: preparedRequest.memoryReserve || 0,
        requestConfig: {
            providerId,
            apiUrl,
            apiKey,
            model,
            temperature: temp,
            topP,
            stream,
            reasoningEffort,
            stopString,
            controller,
            requestReasoning,
            tagStart,
            tagEnd,
            omitTemperature,
            omitTopP,
            omitReasoning,
            omitReasoningEffort
        }
    };
}
