import { ref } from 'vue';
import { Capacitor } from '@capacitor/core';
import * as gdriveAdapter from '@/core/services/adapters/gdriveAdapter.js';

export function useGdriveFolderPicker() {
    const gdriveFolderId = ref('');
    const gdriveFolderStatus = ref('unchecked');
    const isPickingFolder = ref(false);
    const isCreatingFolder = ref(false);
    const pickerError = ref('');
    const folderIdInput = ref('');
    const isNativePlatform = Capacitor.isNativePlatform();

    async function checkGdriveFolder() {
        gdriveFolderStatus.value = 'checking';
        pickerError.value = '';
        try {
            const folderId = await gdriveAdapter.getGlazeFolderId();
            gdriveFolderId.value = folderId || '';
            gdriveFolderStatus.value = folderId ? 'found' : 'not_found';
        } catch (e) {
            console.error('[useGdriveFolderPicker] check failed:', e);
            gdriveFolderStatus.value = 'not_found';
            pickerError.value = e.message;
        }
    }

    async function selectExistingFolder() {
        if (isNativePlatform) {
            return await linkFolderById();
        }
        isPickingFolder.value = true;
        pickerError.value = '';
        try {
            const result = await gdriveAdapter.pickFolder();
            if (result) {
                await gdriveAdapter.setGlazeFolderId(result.id);
                gdriveFolderId.value = result.id;
                gdriveFolderStatus.value = 'found';
            }
        } catch (e) {
            console.error('[useGdriveFolderPicker] pick failed:', e);
            pickerError.value = e.message;
        } finally {
            isPickingFolder.value = false;
        }
    }

    async function linkFolderById() {
        const input = folderIdInput.value.trim();
        if (!input) {
            pickerError.value = 'Please enter a folder ID or Google Drive URL';
            return;
        }

        const folderId = gdriveAdapter.extractFolderId(input);
        if (!folderId) {
            pickerError.value = 'Could not parse folder ID from input';
            return;
        }

        isCreatingFolder.value = true;
        pickerError.value = '';
        try {
            await gdriveAdapter.verifyFolderId(folderId);
            await gdriveAdapter.setGlazeFolderId(folderId);
            gdriveFolderId.value = folderId;
            gdriveFolderStatus.value = 'found';
            folderIdInput.value = '';
        } catch (e) {
            console.error('[useGdriveFolderPicker] link failed:', e);
            pickerError.value = e.message || 'Could not access folder. Make sure it exists and is shared with your Google account.';
        } finally {
            isCreatingFolder.value = false;
        }
    }

    async function createNewFolder() {
        isCreatingFolder.value = true;
        pickerError.value = '';
        try {
            await gdriveAdapter.ensureFolder('/Glaze');
            const folderId = await gdriveAdapter.getGlazeFolderId(true);
            if (folderId) {
                await gdriveAdapter.setGlazeFolderId(folderId);
                gdriveFolderId.value = folderId;
            }
            gdriveFolderStatus.value = 'found';
        } catch (e) {
            console.error('[useGdriveFolderPicker] create failed:', e);
            pickerError.value = e.message;
        } finally {
            isCreatingFolder.value = false;
        }
    }

    function resetFolderStatus() {
        gdriveFolderStatus.value = 'unchecked';
        gdriveFolderId.value = '';
        pickerError.value = '';
        folderIdInput.value = '';
    }

    return {
        gdriveFolderId,
        gdriveFolderStatus,
        isPickingFolder,
        isCreatingFolder,
        pickerError,
        folderIdInput,
        isNativePlatform,
        checkGdriveFolder,
        selectExistingFolder,
        linkFolderById,
        createNewFolder,
        resetFolderStatus
    };
}