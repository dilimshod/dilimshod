# Модели Core ML

Эта папка входит в синхронизированную папку Xcode `RoadVision/`: каждый `*.mlpackage` отсюда Xcode автоматически
компилирует в `<имя>.mlmodelc` внутри приложения. Сам этот README исключён из таргета (membership exception в
`project.pbxproj`), поэтому в приложение не копируется.

## RoadVisionDetector.mlpackage — детектор (есть в репозитории)

| Параметр | Значение |
|---|---|
| Исходная модель | Ultralytics **YOLO11n** (`yolo11n.pt`), обучена на COCO (80 классов) |
| Экспорт | `tools/export_yolo_coreml.py --weights yolo11n.pt` (Ultralytics 8.4.218, coremltools 9.0, torch 2.7.1 CPU, Linux) |
| Вход | `image` — цветное изображение 640×640 (RGB); Vision масштабирует кадр сам |
| Доп. входы | `iouThreshold`, `confidenceThreshold` (Double, **необязательные**; по умолчанию 0,45 и 0,25 из слоя NMS) |
| Выходы | `confidence` [N × 80], `coordinates` [N × 4] (x, y, w, h относительно размера изображения) |
| Тип | Pipeline: ML Program (FP16) → NonMaximumSuppression, spec version 6 |
| Размер | ≈ 5,3 МБ |
| Что возвращает Vision | `VNRecognizedObjectObservation` (метка класса COCO + уверенность + нормализованная рамка) |

Используемые приложением классы COCO: `car`, `truck`, `bus`, `motorcycle`, `bicycle`, `person`, `traffic light`,
`stop sign` (сопоставление — `VehicleKind(label:)` в RoadVisionCore). Остальные метки не сопоставляются и не используются.

Проверено при экспорте: спецификация модели прочитана coremltools (входы/выходы/метки выше). **Не проверено в этом
контейнере**: компиляция `coremlc` и запуск на iPhone — это выполняет Xcode (и CI‑сборка) на macOS.

Пересоздать или заменить модель:

```bash
pip install -r tools/requirements.txt
python tools/export_yolo_coreml.py --force                       # YOLO11n, 640, NMS, FP16
python tools/export_yolo_coreml.py --weights yolo26n.pt --force  # новее: YOLO26n
python tools/export_yolo_coreml.py --quantize 8 --force          # ≈ в 2 раза меньше, немного менее точно
```

Приложение ищет модель по имени в таком порядке: `RoadVisionDetector`, `yolo26n`, `yolo11n`, `yolov8n`.
Если модели нет, экран камеры показывает пояснение, а скорость, навигатор и ИИ‑помощник продолжают работать.

## VehicleMakeClassifier.mlpackage — марки авто (нет в репозитории)

Создаётся скриптом `tools/train_make_classifier.py` (обучение на Stanford Cars, 48 марок, экспорт как
классификатор → Vision возвращает `VNClassificationObservation`). Обучение в репозитории **не запускалось**.
Stanford Cars — только для некоммерческих исследований, и в нём почти нет машин узбекского автопарка
(Cobalt, Nexia, Spark, Damas, Gentra, BYD, Chery…). Для реальной точности нужен собственный размеченный датасет.

## Важно: классы моделей не генерируются

В проекте задано `COREML_CODEGEN_LANGUAGE = None`: Xcode не создаёт Swift‑классы для моделей. Приложение загружает
`RoadVisionDetector.mlmodelc` и `VehicleMakeClassifier.mlmodelc` по имени файла из бандла. Поэтому модель можно
заменить файлом с тем же именем без изменений в коде.

## Лицензии

* **Ultralytics YOLO (код и предобученные веса) — AGPL‑3.0.** Модель в этой папке — производная от весов
  Ultralytics и распространяется на тех же условиях. Для личного и исследовательского использования это нормально.
  Если вы распространяете приложение (App Store, TestFlight для посторонних), AGPL требует открыть исходный код всего
  приложения под AGPL‑3.0 — либо нужна коммерческая лицензия Ultralytics Enterprise, либо модель с другой лицензией.
* COCO: аннотации — CC BY 4.0; изображения — условия Flickr (используются только для обучения исходной модели).
* Stanford Cars: только некоммерческое исследовательское использование.
