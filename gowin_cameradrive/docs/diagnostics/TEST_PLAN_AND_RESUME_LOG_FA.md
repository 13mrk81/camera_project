# برنامهٔ آزمون و لاگ ادامه‌پذیر — MATLAB Line Stream

## مبنای ثابت

- Repository: `13mrk81/camera_project`
- کد مرجع: `feature/matlab-line-stream`
- commit مبنا هنگام تهیهٔ گزارش: `7317f729e5de7f0c3f26220417f8236b25b8e672`
- شاخهٔ ثبت: `CAMERA-LINE`
- ابعاد پیش‌فرض: 640×480
- قالب capture: RGB565، دو بایت برای هر پیکسل
- خروجی UART: RGB888، سه بایت برای هر پیکسل
- UART: 115200، 8N1 طبق اسکریپت MATLAB

## اصل اجرا

هر بار فقط یک مرز را آزمایش کن. قبل از هر تغییر RTL:
1. commit و bitstream را ثبت کن؛
2. نتیجهٔ آزمایش baseline را ذخیره کن؛
3. اولین آدرس/خط/کلمهٔ خراب را پیدا کن؛
4. تنها بلوک مسئول را تغییر بده؛
5. همان آزمون و تمام آزمون‌های قبلی را تکرار کن.

---

## Test 0 — تثبیت نسخه و artifact

- [ ] `git rev-parse HEAD` در clone محلی را ثبت کن.
- [ ] مطمئن شو HEAD برابر commit مبنای بالا یا commit بعدیِ مستند در همین شاخه است.
- [ ] از داخل Gowin، Top و فایل‌های پروژه را با `HYPER_RAM_CONTROL.gprj` تطبیق بده.
- [ ] زمان ساخت bitstream و hash فایل bitstream را ثبت کن.
- [ ] نسخهٔ MATLAB و نام COM/tty را ثبت کن.
- [ ] تأیید کن MATLAB فقط receiver است و از سمت PC هیچ byteای ارسال نمی‌کند.

**قبولی:** معلوم باشد bitstream دقیقاً از کدام commit ساخته شده است.

## Test 1 — آزمون مستقل HyperRAM (اولویت اول)

دوربین و UART را از مسئله حذف کن. یک تست موقت یا testbench بساز که:
- در بازه‌ای امن از حافظه، به هر آدرس/کلمه pattern یکتا بنویسد؛
- حداقل patternها: all-0، all-1، `AAAAAAAA`, `55555555`, walking-1، walking-0؛
- الگوی address-tagged بسازد، مثلاً تابعی از آدرس و مکمل آن؛
- همهٔ کلمات را بخواند و با expected مقایسه کند؛
- اولین mismatch را با address، expected، actual، burst index و beat index گزارش کند.

برای هر command:
- تعداد commandهای پذیرفته‌شده را بشمار؛
- تعداد beatهای `rd_data_valid` را بشمار؛
- بررسی کن دقیقاً 8 beat به ازای هر burst دریافت شود؛
- latency اولین beat و فاصلهٔ beatها را ثبت کن؛
- overflow/underflow و timeout را جداگانه گزارش کن.

**قبولی:** صفر mismatch در کل محدودهٔ تست و تعداد beat برابر تعداد مورد انتظار.
**نکته:** واحد آدرس، stride=16 و command interval=21 را از example همان Gowin IP تأیید کن؛
از روی نام سیگنال یا تطابق writer/reader نتیجه‌گیری نکن.

## Test 2 — capture خام DVP و مرزبندی خط

بدون تغییر مسیر داده، سیگنال‌های زیر را در ILA/GAO مشاهده یا شمارش کن:
- `cam_pclk`
- `cam_vsync`
- `cam_hsync`
- `cam_pix_data[7:0]`
- `cam_byte_valid`
- `cam_line_count`
- `cam_line_byte_count`
- `cap_packed_valid`
- `cap_fifo_full`
- `cap_fifo_wr_level`

برای هر خط فعال، انتظار پایه 640 پیکسل × 2 بایت = 1280 بایت است.
تعداد خطوط مورد انتظار 480 است. در کل فریم 614400 بایت و 153600 کلمهٔ 32 بیتی داریم.

**قبولی:** تعداد بایت هر خط و تعداد خطوط دقیقاً با ابعاد تنظیم‌شده سازگار باشد؛ هیچ FIFO overflow رخ ندهد.
**توجه:** line byte count باید در لحظهٔ پایان هر خط نمونه‌برداری شود؛ شمارش کل فریم به‌تنهایی کافی نیست.

## Test 3 — اثبات byte order و bit lanes

یک صحنهٔ ثابت با نواحی رنگی بزرگ و مشخص مقابل دوربین قرار بده (قرمز، سبز، آبی، سفید، سیاه).
چند ده پیکسل خام DVP را با PCLK و valid ثبت کن و دو بایت هر پیکسل را کنار هم نگه دار.

سپس این فرضیه‌ها را جداگانه ارزیابی کن:
- byte0=MSB و byte1=LSB؛
- byte0=LSB و byte1=MSB؛
- RGB در برابر BGR؛
- جابه‌جایی بیت‌لاین‌ها؛
- sample روی rising در برابر falling edge.

در هر مرحله فقط یک تفسیر را در decoder آفلاین امتحان کن؛ لبهٔ sample را در RTL بدون شواهد تغییر نده.

**قبولی:** رنگ‌های معلوم به RGB565 مورد انتظار تبدیل شوند و مرز پیکسل‌ها ثابت بماند.

## Test 4 — تفکیک writer از readback

برای یک فریم capture:
- `cap_byte_count` باید 614400 باشد.
- `cap_word_count` باید 153600 باشد.
- `write_word_count` باید 153600 شود.
- `capture_crc` و `write_crc` باید برابر باشند.

اگر capture CRC و write CRC برابر نیستند، مسئله را در FIFO capture، خواندن FIFO، burst buffer یا writer جست‌وجو کن.
اگر برابرند، هنوز صحت ذخیره در حافظه اثبات نشده است؛ به readback برو.

## Test 5 — readback و output FIFO

در readout:
- برای هر خط 320 کلمه باید خوانده شود.
- برای هر خط 40 burst و هر burst هشت beat انتظار می‌رود.
- عمق output FIFO برابر 512 کلمه است و باید ظرفیت یک خط را داشته باشد.
- `reader_error`، `serializer_error`، `output_fifo_level`، `fifo_full`، `fifo_empty` و `rd_data_valid` را ثبت کن.
- هیچ beat معتبر نباید خارج از `ST_WAIT_BURST_DATA` برسد.
- هر command باید دقیقاً هشت beat پاسخ بدهد.

**قبولی:** readback CRC با capture CRC برابر و تعداد کلمات/بایت‌ها کامل باشد.
اگر CRC متفاوت است، اولین آدرس/خط/beat متفاوت را پیدا کن؛ فقط به CRC نهایی اکتفا نکن.

## Test 6 — UART و MATLAB

در MATLAB این آمار را ذخیره کن:
- تعداد packetهای STAGE، READY، LINE، DONE و ERROR؛
- تعداد candidateهای CRC نامعتبر؛
- discarded bytes هنگام resynchronization؛
- شمارهٔ خطوط دریافت‌شده؛
- خطوط تکراری و خارج از ترتیب؛
- طول payload هر LINE؛
- READY width/height و pixel format؛
- آمار DONE.

برای 640×480:
- READY باید 640×480 و RGB888 باشد.
- هر LINE باید 1920 بایت payload داشته باشد.
- sequence خطوط باید دقیقاً 0 تا 479 باشد.
- تعداد خطوط یکتا 480 باشد.
- تعداد بایت پیکسل RGB888 برابر 921600 باشد.
- DONE باید 480 خط، 307200 پیکسل و 921600 بایت UART گزارش کند.

**قبولی:** تمام packetها CRC معتبر، sequence پیوسته و شمارنده‌ها کامل باشند.

## Test 7 — الگوی هندسی برای تشخیص portrait/transpose

تصویر طبیعی برای تشخیص ترتیب کافی نیست. از الگوی نامتقارن استفاده کن:
- یک نوار قرمز فقط در بالای تصویر؛
- یک نوار سبز فقط در سمت چپ؛
- یک مربع سفید در گوشهٔ بالا-چپ؛
- یک مربع آبی در گوشهٔ پایین-راست؛
- در صورت امکان شمارهٔ خط یا الگوی شدت متفاوت در هر خط.

نتیجه را با sequence خطوط و READY geometry مقایسه کن.
اگر خطوط از 0 تا 479 درست‌اند اما تصویر چرخیده است، مسیر نمایش/ابعاد را بررسی کن؛
اگر sequence یا محتوای خط غلط است، مشکل قبل از MATLAB است.

---

## معیار توقف و انتخاب مسیر اصلاح

- HyperRAM independent test fail → فقط حافظه/adapter/address/timing بررسی شود.
- HyperRAM pass ولی capture line count fail → camera_interface و DVP timing بررسی شود.
- Capture/write/readback CRC برابر ولی رنگ غلط → byte order/bit-lane/sensor format بررسی شود.
- Readback CRC pass ولی packet CRC fail → UART physical path یا packet engine بررسی شود.
- Packet CRC pass ولی row order fail → sequence/line protocol/MATLAB mapping بررسی شود.

## لاگ اجرا

هر بار یک بلوک زیر را کپی و تکمیل کن.

### Run 000 — هنوز روی برد اجرا نشده

- Date/time:
- Git commit:
- Bitstream SHA256:
- Gowin EDA version:
- MATLAB version:
- Frame size:
- UART port / baud:
- Test number:
- Setup / scene:
- Expected:
- Actual:
- First mismatch (address/line/word/beat):
- Capture CRC32:
- Write CRC32:
- Readback CRC32:
- Packet CRC errors:
- Discarded UART bytes:
- FIFO overflow / underflow:
- Reader / serializer / protocol error:
- Pass / fail:
- Interpretation:
- Next action:

## نکات باز برای بررسی کد

1. اثبات معنای آدرس و stride شانزده در IP تولیدشدهٔ HyperRAM.
2. اثبات حداقل فاصلهٔ فرمان و latency پاسخ در فرکانس واقعی `usr_clk`.
3. قابل مشاهده کردن `system_ok`، `integrity_error` و اولین علت خطا روی ILA/GAO یا telemetry.
4. اضافه کردن شمارندهٔ مستقل تعداد beatهای دریافتی برای هر burst و نگهداری first-fault snapshot.
5. ثبت شمارندهٔ بایت هر خط از camera_interface؛ صرفاً total byte count کافی نیست.
6. تأیید این‌که تمام sticky errorها و شمارنده‌ها در هر trigger جدید به‌درستی reset می‌شوند؛ نسخهٔ فعلی one-shot است و برای چند فریم بدون reset نباید فرض رفتار کرد.
