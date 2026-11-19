# GC0308 / HyperRAM / MATLAB عیب‌یابی — مبنای نسخه

> **مبنای قطعی این پرونده:** شاخهٔ `feature/matlab-line-stream` با commit
> `7317f729e5de7f0c3f26220417f8236b25b8e672`.
>
> شاخهٔ `CAMERA-LINE` برای ثبت تحقیق و اصلاح مستندات، از همین commit منشعب/هم‌تراز شده است.
> تمام نتیجه‌گیری‌های RTL در این پوشه فقط به همین نسخه اشاره دارند.

## هدف

پیدا کردن علت خرابی رنگ، نوارهای افقی/عمودی، جابه‌جایی ترتیب پیکسل/خط و هرگونه از دست رفتن داده در مسیر:

`GC0308 DVP → camera_interface → RGB565 packer → capture FIFO → HyperRAM writer → HyperRAM → line reader → output FIFO → RGB565/RGB888 serializer → framed UART → MATLAB`

این پرونده عمداً تغییر RTL پیشنهاد نمی‌کند مگر پس از آزمون تفکیکی و ثبت شواهد.

## فایل‌ها

- [ROOT_CAUSE_ANALYSIS_FA.md](ROOT_CAUSE_ANALYSIS_FA.md): معماری واقعی نسخهٔ مبنا، یافته‌ها، ریسک‌ها و رتبه‌بندی فرضیه‌ها.
- [TEST_PLAN_AND_RESUME_LOG_FA.md](TEST_PLAN_AND_RESUME_LOG_FA.md): ترتیب آزمون‌ها، معیار قبولی/رد و لاگ ادامه‌پذیر.

## فایل‌های مرجع کد

- `src/Camera_HyperRAM_OneFrame.vhd`
- `src/camera_interface.vhd`
- `src/rgb565_frame_packer.vhd`
- `src/async_fifo_32.vhd`
- `src/gowin_hyperram_read_adapter.vhd`
- `src/hyperram_line_reader.vhd`
- `src/hyperram_line_readout.vhd`
- `src/rgb565_line_serializer.vhd`
- `src/camera_uart_frame_protocol.vhd`
- `src/frame_integrity_checker.vhd`
- `matlab/matlab_gc0308_hyperram_receiver.m`
- `HYPER_RAM_CONTROL.gprj` و `src/hyper_ctrl.cst`

## قواعد جلوگیری از مخلوط شدن نسخه‌ها

1. هر تحلیل RTL باید commit مبنا را ذکر کند.
2. تغییر در `feature/matlab-line-stream` خودکار وارد این شاخه نمی‌شود؛ برای تحلیل تازه باید دو شاخه دوباره مقایسه شوند.
3. این شاخه می‌تواند مستندات تشخیصی اضافه داشته باشد؛ فایل‌های اجرایی `gowin_cameradrive/src`، پروژهٔ Gowin و MATLAB باید با نسخهٔ مرجع یکسان بمانند، مگر تغییر صریح و مستند درخواست شود.
4. در هر آزمایش، bitstream، commit، نسخهٔ MATLAB، اندازهٔ فریم، نرخ UART و نتیجهٔ CRC ثبت شود.
5. CRC موفق فقط صحت انتقال نسبت به دادهٔ مبنا را نشان می‌دهد؛ اگر داده در ابتدای مسیر اشتباه sample یا تفسیر شده باشد، CRC نیز می‌تواند موفق باشد.

## وضعیت فعلی

- [x] مبنای شاخه با `feature/matlab-line-stream` هم‌تراز شد.
- [x] RTL و اسکریپت MATLAB شاخهٔ مبنا بررسی شدند.
- [x] تحلیل قبلی که UART را متصل‌نشده فرض می‌کرد، کنار گذاشته شد.
- [ ] آزمون مستقل HyperRAM با الگوی آدرس‌دار روی برد اجرا شود.
- [ ] آزمون رنگ/byte-order با الگوی مرجع انجام شود.
- [ ] شمارنده‌ها و پرچم‌های سلامت با ILA یا telemetry قابل مشاهده شوند.
- [ ] لاگ واقعی یک فریم سالم و یک فریم خراب ثبت شود.
