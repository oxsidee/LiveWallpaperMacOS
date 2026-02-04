# Инструкция по сборке для распространения

## Вариант 1: Через Xcode (рекомендуется)

### Шаг 1: Настройка подписи

1. Откройте проект в Xcode
2. Выберите проект в навигаторе → Target "LiveWallpaper"
3. Перейдите на вкладку **Signing & Capabilities**
4. Убедитесь, что:
   - **Team** выбран (9GJK56NW98)
   - **Signing Certificate**: "Apple Development" (для тестирования) или "Developer ID Application" (для распространения)

### Шаг 2: Сборка Release версии

1. В Xcode выберите схему: **Product → Scheme → LiveWallpaper**
2. Выберите конфигурацию: **Product → Destination → Any Mac**
3. Выберите сборку: **Product → Archive** (или `Cmd+Shift+B`)

### Шаг 3: Экспорт приложения

1. После создания архива откроется окно **Organizer**
2. Выберите созданный архив
3. Нажмите **Distribute App**
4. Выберите **Copy App** (для распространения вне App Store)
5. Выберите опции:
   - ✅ **Include bitcode** (если требуется)
   - ✅ **Strip Swift symbols** (для уменьшения размера)
6. Нажмите **Export**
7. Выберите папку для сохранения

### Шаг 4: Создание DMG (опционально)

```bash
# Создайте папку для DMG
mkdir -p build/DMG
cp -R "путь/к/LiveWallpaper.app" build/DMG/

# Создайте симлинк на Applications
ln -s /Applications build/DMG/Applications

# Создайте DMG
hdiutil create -volname "LiveWallpaper" \
    -srcfolder build/DMG \
    -ov -format UDZO \
    build/LiveWallpaper.dmg
```

## Вариант 2: Через командную строку

### Использование скрипта build-release.sh

```bash
# Сделайте скрипт исполняемым
chmod +x build-release.sh

# Запустите сборку
./build-release.sh
```

Скрипт автоматически:
- Очистит предыдущие сборки
- Создаст архив
- Экспортирует приложение
- Создаст ZIP архив
- Создаст DMG (если доступен hdiutil)

## Вариант 3: Ручная сборка через xcodebuild

```bash
# 1. Очистка
xcodebuild clean \
    -project LiveWallpaper.xcodeproj \
    -scheme LiveWallpaper \
    -configuration Release

# 2. Создание архива
xcodebuild archive \
    -project LiveWallpaper.xcodeproj \
    -scheme LiveWallpaper \
    -configuration Release \
    -archivePath build/LiveWallpaper.xcarchive \
    CODE_SIGN_IDENTITY="Apple Development" \
    DEVELOPMENT_TEAM="9GJK56NW98"

# 3. Экспорт приложения
xcodebuild -exportArchive \
    -archivePath build/LiveWallpaper.xcarchive \
    -exportPath build/Export \
    -exportOptionsPlist ExportOptions.plist
```

## Установка на другие MacBook'и

### Способ 1: Через Finder (рекомендуется)

1. Скопируйте `LiveWallpaper.app` в папку `/Applications/`
2. При первом запуске macOS может заблокировать приложение
3. Откройте **System Settings → Privacy & Security**
4. Нажмите **Open Anyway** рядом с предупреждением о LiveWallpaper

### Способ 2: Через Terminal

```bash
# 1. Скопируйте приложение
cp -R LiveWallpaper.app /Applications/

# 2. Удалите атрибут quarantine (обход Gatekeeper)
xattr -d com.apple.quarantine /Applications/LiveWallpaper.app

# 3. Запустите приложение
open /Applications/LiveWallpaper.app
```

### Способ 3: Через Control+Click

1. Скопируйте приложение в `/Applications/`
2. **Control+Click** (или правой кнопкой) на приложении
3. Выберите **Open**
4. В диалоге нажмите **Open** (это нужно сделать только один раз)

## Нотификация (Notarization) - для распространения

Если вы хотите распространять приложение без предупреждений Gatekeeper, нужно нотифицировать его:

```bash
# 1. Создайте архив для нотификации
xcrun notarytool submit LiveWallpaper.zip \
    --apple-id "your@email.com" \
    --team-id "9GJK56NW98" \
    --password "app-specific-password" \
    --wait

# 2. После успешной нотификации, добавьте тикет в приложение
xcrun stapler staple LiveWallpaper.app
```

**Примечание**: Для нотификации нужен:
- Apple ID с доступом к Developer Program
- App-specific password
- Developer ID Application сертификат

## Проверка подписи

Проверьте, что приложение правильно подписано:

```bash
codesign -dv --verbose=4 LiveWallpaper.app
codesign --verify --deep --strict --verbose=2 LiveWallpaper.app
```

## Распространение

### Через GitHub Releases

1. Создайте тег версии:
   ```bash
   git tag -a v2.0.0 -m "Release v2.0.0"
   git push origin v2.0.0
   ```

2. Создайте release на GitHub:
   - Перейдите в **Releases → Draft a new release**
   - Выберите тег
   - Загрузите ZIP или DMG файл
   - Добавьте описание изменений

### Через DMG

1. Создайте DMG (см. выше)
2. Загрузите на файлообменник или GitHub Releases
3. Пользователи скачивают и монтируют DMG
4. Перетаскивают приложение в Applications

## Решение проблем

### "App is damaged and can't be opened"

```bash
xattr -d com.apple.quarantine /Applications/LiveWallpaper.app
```

### "Developer cannot be verified"

1. System Settings → Privacy & Security
2. Нажмите "Open Anyway" рядом с предупреждением

### Daemon не запускается в release версии

Проверьте логи в Console.app:
- Фильтр: "LiveWallpaper" или "wallpaperdaemon"
- Ищите сообщения с 🔍, ❌, ✅

## Требования для распространения

- ✅ macOS 26.0+ (установлено в проекте)
- ✅ Правильная подпись кода
- ✅ Все зависимости включены в bundle
- ⚠️ Hardened Runtime отключен (может вызвать проблемы)
- ⚠️ App Sandbox отключен (требуется для работы daemon)
