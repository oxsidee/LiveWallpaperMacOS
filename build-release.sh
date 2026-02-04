#!/bin/bash

# Скрипт для сборки LiveWallpaper для распространения
# Использование: ./build-release.sh

set -e

PROJECT_NAME="LiveWallpaper"
SCHEME="LiveWallpaper"
CONFIGURATION="Release"
ARCHIVE_PATH="build/${PROJECT_NAME}.xcarchive"
EXPORT_PATH="build/Export"
APP_PATH="${EXPORT_PATH}/${PROJECT_NAME}.app"
DMG_PATH="build/${PROJECT_NAME}.dmg"

echo "🔨 Начинаем сборку ${PROJECT_NAME}..."

# Очистка предыдущих сборок
echo "🧹 Очистка предыдущих сборок..."
rm -rf build
mkdir -p build

# Сборка архива
echo "📦 Создание архива..."
xcodebuild clean \
    -project "${PROJECT_NAME}.xcodeproj" \
    -scheme "${SCHEME}" \
    -configuration "${CONFIGURATION}"

xcodebuild archive \
    -project "${PROJECT_NAME}.xcodeproj" \
    -scheme "${SCHEME}" \
    -configuration "${CONFIGURATION}" \
    -archivePath "${ARCHIVE_PATH}" \
    CODE_SIGN_IDENTITY="Apple Development" \
    DEVELOPMENT_TEAM="9GJK56NW98"

if [ ! -d "${ARCHIVE_PATH}" ]; then
    echo "❌ Ошибка: архив не создан"
    exit 1
fi

echo "✅ Архив создан: ${ARCHIVE_PATH}"

# Экспорт приложения
echo "📤 Экспорт приложения..."
mkdir -p "${EXPORT_PATH}"

# Копируем приложение из архива
APP_IN_ARCHIVE="${ARCHIVE_PATH}/Products/Applications/${PROJECT_NAME}.app"
if [ -d "${APP_IN_ARCHIVE}" ]; then
    cp -R "${APP_IN_ARCHIVE}" "${EXPORT_PATH}/"
    echo "✅ Приложение скопировано"
else
    echo "❌ Ошибка: приложение не найдено в архиве"
    exit 1
fi

# Проверка подписи
echo "🔐 Проверка подписи..."
codesign -dv --verbose=4 "${APP_PATH}" 2>&1 | head -20 || echo "⚠️ Предупреждение: проблемы с подписью"

# Создание ZIP архива
echo "📦 Создание ZIP архива..."
cd "${EXPORT_PATH}"
zip -r "../${PROJECT_NAME}.zip" "${PROJECT_NAME}.app"
cd - > /dev/null
echo "✅ ZIP архив создан: build/${PROJECT_NAME}.zip"

# Создание DMG (опционально, требует hdiutil)
if command -v hdiutil &> /dev/null; then
    echo "💿 Создание DMG..."
    rm -f "${DMG_PATH}"
    
    # Создаем временную папку для DMG
    DMG_TEMP="build/DMG"
    rm -rf "${DMG_TEMP}"
    mkdir -p "${DMG_TEMP}"
    
    # Копируем приложение
    cp -R "${APP_PATH}" "${DMG_TEMP}/"
    
    # Создаем симлинк на Applications
    ln -s /Applications "${DMG_TEMP}/Applications"
    
    # Создаем DMG
    hdiutil create -volname "${PROJECT_NAME}" \
        -srcfolder "${DMG_TEMP}" \
        -ov -format UDZO \
        "${DMG_PATH}"
    
    echo "✅ DMG создан: ${DMG_PATH}"
else
    echo "⚠️ hdiutil не найден, пропускаем создание DMG"
fi

echo ""
echo "✅ Сборка завершена!"
echo ""
echo "📁 Файлы:"
echo "   - Приложение: ${APP_PATH}"
echo "   - ZIP: build/${PROJECT_NAME}.zip"
if [ -f "${DMG_PATH}" ]; then
    echo "   - DMG: ${DMG_PATH}"
fi
echo ""
echo "⚠️  ВАЖНО: Для установки на других MacBook'ах:"
echo "   1. Скопируйте приложение в /Applications/"
echo "   2. Выполните: xattr -d com.apple.quarantine /Applications/${PROJECT_NAME}.app"
echo "   3. Или: Control+Click → Open (первый запуск)"
echo ""
