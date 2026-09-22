using System;
using System.Collections.Generic;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using TMPro;
using UnityEngine;
using UnityEngine.TextCore.LowLevel;
using UnityEngine.UI;

namespace FontReplacerPlugin
{
    public static class FontReplacerBootstrap
    {
        private const uint FR_PRIVATE = 0x10;

        [DllImport("gdi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern int AddFontResourceExW(string lpszFilename, uint fl, IntPtr pdv);

        [DllImport("gdi32.dll", SetLastError = true)]
        private static extern IntPtr AddFontMemResourceEx(IntPtr pbFont, uint cbFont, IntPtr pdv, out uint pcFonts);

        private static bool _installed;
        private static bool _hookInstalled;
        private static string _fontPath;
        private static TMP_FontAsset _tmpFont;
        private static Font _legacyFont;
        private static float _nextScanTime;
        private static float _nextFontTryTime;
        private static int _fontCreateAttempts;
        private static bool _fontRegistrationTried;
        private static bool _fontCreationTried;
        private static byte[] _fontBytes;
        private static GCHandle _fontMemHandle;

        public static void Install()
        {
            if (_installed) return;
            try
            {
                _fontPath = Path.Combine(Application.streamingAssetsPath, "zh-cn.ttf");
                if (!File.Exists(_fontPath)) _fontPath = "/mis/zh-cn.ttf";
                if (!_hookInstalled)
                {
                    _hookInstalled = true;
                    Application.onBeforeRender += OnBeforeRender;
                }
                _installed = true;
                Debug.Log("[FontReplacer] installed, fontPath=" + _fontPath);
                ReplaceImmediate();
            }
            catch (Exception e)
            {
                Debug.LogError("[FontReplacer] Install failed: " + e);
            }
        }

        private static void OnBeforeRender()
        {
            try
            {
                if (!_fontRegistrationTried) RegisterFont();

                if (_tmpFont == null && Time.realtimeSinceStartup >= _nextFontTryTime)
                {
                    _nextFontTryTime = Time.realtimeSinceStartup + 2f;
                    CreateFonts();
                }

                if (Time.realtimeSinceStartup < _nextScanTime) return;
                _nextScanTime = Time.realtimeSinceStartup + 1f;
                ReplaceAll();
            }
            catch (Exception e)
            {
                Debug.LogError("[FontReplacer] OnBeforeRender failed: " + e);
            }
        }

        private static void ReplaceImmediate()
        {
            _nextScanTime = 0f;
            ReplaceAll();
        }

        private static void RegisterFont()
        {
            _fontRegistrationTried = true;
            try
            {
                if (!File.Exists(_fontPath))
                {
                    Debug.LogError("[FontReplacer] font file not found: " + _fontPath);
                    return;
                }

                try
                {
                    int added = AddFontResourceExW(Path.GetFullPath(_fontPath), FR_PRIVATE, IntPtr.Zero);
                    if (added > 0) Debug.Log("[FontReplacer] AddFontResourceEx added=" + added);
                }
                catch (Exception e)
                {
                    Debug.LogWarning("[FontReplacer] AddFontResourceEx failed: " + e.Message);
                }

                // Keep the pinned font memory alive for the whole process lifetime.
                // AddFontMemResourceEx does not copy the font data.
                _fontBytes = File.ReadAllBytes(_fontPath);
                _fontMemHandle = GCHandle.Alloc(_fontBytes, GCHandleType.Pinned);
                uint fontCount;
                IntPtr result = AddFontMemResourceEx(_fontMemHandle.AddrOfPinnedObject(), (uint)_fontBytes.Length, IntPtr.Zero, out fontCount);
                if (result != IntPtr.Zero) Debug.Log("[FontReplacer] AddFontMemResourceEx added=" + fontCount);
                else Debug.LogError("[FontReplacer] font registration failed win32err=" + Marshal.GetLastWin32Error());
            }
            catch (Exception e)
            {
                Debug.LogError("[FontReplacer] RegisterFont failed: " + e);
            }
        }

        private static void CreateFonts()
        {
            _fontCreateAttempts++;
            List<string> families = new List<string>();
            try
            {
                byte[] bytes = File.ReadAllBytes(_fontPath);
                families.AddRange(ExtractFamilyNames(bytes));
            }
            catch (Exception e)
            {
                Debug.LogWarning("[FontReplacer] TTF parse failed: " + e.Message);
            }
            AddUnique(families, "Default_SC");
            AddUnique(families, "Default SC");
            AddUnique(families, "HanYiWenHei");
            AddUnique(families, "汉仪文黑");
            AddUnique(families, "zh-cn");

            if (_fontCreateAttempts == 1)
                Debug.Log("[FontReplacer] families=" + string.Join("|", families.ToArray()));

            // Create a legacy dynamic Font once, used for UnityEngine.UI.Text / TextMesh.
            if (_legacyFont == null)
            {
                try
                {
                    _legacyFont = Font.CreateDynamicFontFromOSFont(families.ToArray(), 90);
                    if (_legacyFont != null)
                    {
                        _legacyFont.RequestCharactersInTexture("测试中文", 90);
                        Debug.Log("[FontReplacer] legacy names=" + (_legacyFont.fontNames == null ? "null" : string.Join("|", _legacyFont.fontNames)) + " hasChinese=" + _legacyFont.HasCharacter('中'));
                    }
                }
                catch (Exception e)
                {
                    Debug.LogError("[FontReplacer] CreateDynamicFontFromOSFont failed: " + e.Message);
                }
            }

            if (_tmpFont != null)
                return;

            // Best path: ask TMP/FontEngine to read the TTF file directly.
            // This does not rely on GDI/OS font enumeration at all.
            try
            {
                string fullPath = Path.GetFullPath(_fontPath);
                TMP_FontAsset fileAsset = TMP_FontAsset.CreateFontAsset(fullPath, 0, 90, 9, GlyphRenderMode.SDFAA, 1024, 1024);
                if (fileAsset != null)
                {
                    fileAsset.name = "zh-cn Runtime Font";
                    fileAsset.atlasPopulationMode = AtlasPopulationMode.Dynamic;
                    fileAsset.isMultiAtlasTexturesEnabled = true;
                    string missing;
                    bool added = fileAsset.TryAddCharacters("中文测试你好世界", out missing);
                    Debug.Log("[FontReplacer] TMP file font created path=" + fullPath + " added=" + added + " missing=" + (missing ?? string.Empty));
                    _tmpFont = fileAsset;
                    TMP_Settings.defaultFontAsset = _tmpFont;
                    if (TMP_Settings.fallbackFontAssets != null && !TMP_Settings.fallbackFontAssets.Contains(_tmpFont))
                        TMP_Settings.fallbackFontAssets.Insert(0, _tmpFont);
                    return;
                }
                Debug.LogWarning("[FontReplacer] TMP file font creation returned null, trying family names");
            }
            catch (Exception fileError)
            {
                Debug.LogWarning("[FontReplacer] TMP file font creation failed: " + fileError.Message);
            }

            // Fallback: create the TMP font asset directly from an OS font family name.
            string[] styles = { "Regular", "Normal", "Book", "Heavy", "85W", "" };
            Exception lastError = null;
            for (int i = 0; i < families.Count; i++)
            {
                for (int j = 0; j < styles.Length; j++)
                {
                    try
                    {
                        TMP_FontAsset asset = TMP_FontAsset.CreateFontAsset(families[i], styles[j], 90);
                        if (asset == null) continue;
                        asset.name = "zh-cn Runtime Font";
                        asset.atlasPopulationMode = AtlasPopulationMode.Dynamic;
                        asset.isMultiAtlasTexturesEnabled = true;
                        _tmpFont = asset;
                        try
                        {
                            string missing;
                            bool added = _tmpFont.TryAddCharacters("中文测试你好世界", out missing);
                            Debug.Log("[FontReplacer] TryAddCharacters=" + added + " missing=" + (missing ?? string.Empty));
                        }
                        catch (Exception glyphError)
                        {
                            Debug.LogWarning("[FontReplacer] TryAddCharacters failed: " + glyphError.Message);
                        }
                        TMP_Settings.defaultFontAsset = _tmpFont;
                        if (TMP_Settings.fallbackFontAssets != null && !TMP_Settings.fallbackFontAssets.Contains(_tmpFont))
                            TMP_Settings.fallbackFontAssets.Insert(0, _tmpFont);
                        Debug.Log("[FontReplacer] TMP font asset created family=" + families[i] + " style=" + styles[j]);
                        return;
                    }
                    catch (Exception e)
                    {
                        lastError = e;
                    }
                }
            }

            if (_fontCreateAttempts <= 3 || _fontCreateAttempts % 10 == 0)
                Debug.LogError("[FontReplacer] TMP font creation failed: " + (lastError == null ? "all candidates returned null" : lastError.Message));
        }

        private static void ReplaceAll()
        {
            if (_tmpFont != null)
            {
                UnityEngine.Object[] texts = Resources.FindObjectsOfTypeAll(typeof(TMP_Text));
                for (int i = 0; i < texts.Length; i++)
                {
                    TMP_Text text = texts[i] as TMP_Text;
                    if (text != null && text.font != _tmpFont)
                    {
                        text.font = _tmpFont;
                        text.SetAllDirty();
                    }
                }
            }

            if (_legacyFont != null)
            {
                UnityEngine.Object[] uiTexts = Resources.FindObjectsOfTypeAll(typeof(Text));
                for (int i = 0; i < uiTexts.Length; i++)
                {
                    Text text = uiTexts[i] as Text;
                    if (text != null && text.font != _legacyFont)
                    {
                        text.font = _legacyFont;
                        text.SetAllDirty();
                    }
                }

                UnityEngine.Object[] meshTexts = Resources.FindObjectsOfTypeAll(typeof(TextMesh));
                for (int i = 0; i < meshTexts.Length; i++)
                {
                    TextMesh text = meshTexts[i] as TextMesh;
                    if (text != null && text.font != _legacyFont) text.font = _legacyFont;
                }
            }
        }

        private static void AddUnique(List<string> list, string value)
        {
            if (!string.IsNullOrEmpty(value) && !list.Contains(value)) list.Add(value);
        }

        private static List<string> ExtractFamilyNames(byte[] data)
        {
            List<string> result = new List<string>();
            if (data == null || data.Length < 12) return result;
            int numTables = ReadU16(data, 4);
            for (int i = 0; i < numTables; i++)
            {
                int rec = 12 + i * 16;
                if (rec + 16 > data.Length) break;
                string tag = Encoding.ASCII.GetString(data, rec, 4);
                if (tag != "name") continue;
                int tableOffset = (int)ReadU32(data, rec + 8);
                if (tableOffset + 6 > data.Length) break;
                int count = ReadU16(data, tableOffset + 2);
                int stringOffset = ReadU16(data, tableOffset + 4);
                for (int j = 0; j < count; j++)
                {
                    int nameRec = tableOffset + 6 + j * 12;
                    if (nameRec + 12 > data.Length) break;
                    int platformId = ReadU16(data, nameRec);
                    int nameId = ReadU16(data, nameRec + 6);
                    if (nameId != 1 && nameId != 4) continue;
                    int length = ReadU16(data, nameRec + 8);
                    int offset = ReadU16(data, nameRec + 10);
                    int start = tableOffset + stringOffset + offset;
                    if (start < 0 || start + length > data.Length) continue;
                    string value;
                    if (platformId == 0 || platformId == 3)
                        value = Encoding.BigEndianUnicode.GetString(data, start, length);
                    else
                        value = Encoding.UTF8.GetString(data, start, length);
                    value = value.Replace("\0", string.Empty).Trim();
                    if (!string.IsNullOrEmpty(value) && !result.Contains(value)) result.Add(value);
                }
            }
            return result;
        }

        private static int ReadU16(byte[] data, int offset) { return (data[offset] << 8) | data[offset + 1]; }
        private static uint ReadU32(byte[] data, int offset) { return ((uint)data[offset] << 24) | ((uint)data[offset + 1] << 16) | ((uint)data[offset + 2] << 8) | data[offset + 3]; }
    }
}
