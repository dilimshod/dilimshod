# Естественный голос RoadVis (клипы Microsoft Edge)

Системный голос iOS звучит роботизированно, а узбекский читается турецким голосом. Поэтому подсказки можно
один раз записать нейросетевыми голосами Microsoft Edge и положить в приложение: оно собирает фразы из клипов
(«300 metrdan keyin» + «o‘ngga buriling»), а всё, чего нет в записи (названия улиц, редкие числа), читает
системным голосом, как раньше.

## Одна команда на Mac (из корня репозитория)

```bash
python3 -m pip install --user edge-tts && python3 RoadVis/tools/generate_voice_clips.py --uz-voice uz-UZ-MadinaNeural --ru-voice ru-RU-SvetlanaNeural --en-voice en-US-JennyNeural --rate +5%
```

Затем пересоберите приложение (`bash RoadVis/tools/install_on_iphone.sh`). Или всё сразу:
`bash RoadVis/tools/install_on_iphone.sh --voices` — если клипов ещё нет, скрипт сам поставит edge-tts и
сгенерирует их (свои голоса: `VOICE_ARGS="--uz-voice uz-UZ-SardorNeural" bash … --voices`).

- Голоса: `uz-UZ-MadinaNeural` (жен.) / `uz-UZ-SardorNeural` (муж.), `ru-RU-SvetlanaNeural` / `ru-RU-DmitryNeural`,
  `en-US-JennyNeural` / `en-US-GuyNeural`. Темп: `--rate +5%` или `--rate=-10%` (отрицательное — через `=`).
- Результат: `RoadVis/RoadVis/VoiceClips/<язык>_<id>.m4a` (AAC, моно, 24 кГц, через `afconvert`; без него —
  `.mp3`, iOS тоже играет). ≈ 360 файлов, несколько МБ, 2–4 минуты.
- Готовые файлы пропускаются; `--force` — перезаписать всё, `--only turn_right,n_300` — отдельные фразы,
  `--languages uz` — один язык, `--dry-run` — только список. При смене голоса/темпа язык перегенерируется сам.
- Если `pip install --user` запрещён (Homebrew Python): `python3 -m venv ~/.edge && ~/.edge/bin/pip install edge-tts`
  и запуск через `~/.edge/bin/python RoadVis/tools/generate_voice_clips.py …`.
- В приложении: Настройки → Язык → «Естественный голос: установлено N из M фраз» и переключатель.

## Тексты фраз

`tools/voice_phrases.json` экспортируется из `Packages/RoadVisCore/Sources/RoadVisCore/VoiceClipCatalog.swift`.
Меняйте тексты в Swift и обновляйте JSON:

```bash
cd RoadVis/Packages/RoadVisCore && RV_WRITE_VOICE_JSON=1 swift test --filter VoicePhraseTests
```

(обычный `swift test` проверяет, что JSON не устарел). После правки текстов — `generate_voice_clips.py --only <id>`.

## Лицензия — важно

edge-tts обращается к неофициальному бесплатному сервису функции «Читать вслух» браузера Microsoft Edge.
Условия Microsoft, скорее всего, **не разрешают распространять** сгенерированное аудио. Для личного тестирования
это нормально, но **перед публикацией приложения клипы нужно заменить** (Azure AI Speech по платной лицензии,
своя запись диктора и т. п.). Поэтому папка `RoadVis/RoadVis/VoiceClips/` добавлена в `.gitignore`.
