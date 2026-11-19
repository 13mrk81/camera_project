# نسخه یکپارچه پژوهش GC0308 برای FPGA

> **وضعیت سند:** نسخه تجمیع‌شده؛ محتوای گزارش پایه حفظ شده و گزارش‌های مکمل به‌صورت پیوست کامل اضافه شده‌اند.  
> **شاخه:** `CAMERA-LINE`  
> **روش ادغام:** هیچ یافته فنی، توضیح، جدول، قطعه‌کد یا منبعی از گزارش‌های ورودی عمداً حذف نشده است. برای جلوگیری از حذف جزئیات، متن دو گزارش مکمل در پیوست‌های مستقل نگهداری شده‌اند؛ بخش اصلی این سند، گزارش فارسی پایه است.  
> **نکته درباره فایل مکمل:** فایل دوم علاوه بر گزارش فنی، شامل متن چند گزارش و یادداشت‌های مکالمه‌ای در ابتدا/انتها بود. فقط جداکننده‌های مکالمه‌ای حذف شده‌اند؛ متن گزارش‌ها در پیوست‌ها حفظ شده است.

## راهنمای ساختار نسخه ادغام‌شده

1. **گزارش اصلی فارسی:** متن کامل فایل `GC0308_FPGA_CAMERA_RESEARCH_FA.md` پیشین، بدون حذف.
2. **پیوست A — Technical Investigation Report:** متن گزارش فنی انگلیسی موجود در فایل دوم، حفظ‌شده به‌صورت کامل.
3. **پیوست B — Evidence-Based Failure Analysis & Debugging Guide:** گزارش مکمل با تمرکز بر شواهد دیتاشیت و درایور Linux، حفظ‌شده به‌صورت کامل.

## جمع‌بندی تلفیقی و اولویت‌های مشترک

با کنار هم گذاشتن گزارش‌ها، یک اصل مهم به دست می‌آید: **درست بودن ابعاد فریم و تعداد کل بایت‌ها، سلامت محتوای تصویر را اثبات نمی‌کند.** خطای قالب/ترتیب بایت، جابه‌جایی فاز بایت، از دست رفتن یک بایت، ترتیب نیم‌کلمه‌ها، CDC، توقف نوشتن HyperRAM یا بازسازی اشتباه در MATLAB می‌تواند فریمی با طول ظاهراً صحیح اما محتوای خراب تولید کند.

### اولویت تشخیص برای معماری Tang Nano 4K

| اولویت | آزمون | معیار پذیرش / نتیجه مورد انتظار | محل احتمالی خطا در صورت شکست |
|---:|---|---|---|
| 0 | خواندن مجدد رجیسترهای سنسور، به‌ویژه `0x24` و `0x26` و ابعاد پنجره | مقدار خوانده‌شده با فرمت و قطبیت مورد انتظار یکسان باشد | SCCB/I²C، جدول initialization یا فرض اشتباه درباره رجیستر |
| 1 | اثبات قالب خروجی واقعی | RGB565 یا یکی از ترتیب‌های YUV422 به‌صورت یکتا انتخاب و در MATLAB نیز همان قرارداد اعمال شود | سنسور، byte order یا parser میزبان |
| 2 | شمارش داده در هر خط فعال | برای 640 پیکسل با 2 بایت/پیکسل، دقیقاً 1280 بایت در هر خط | HREF، windowing، PCLK، byte phase یا شمارنده |
| 3 | ثبت یک خط در BRAM بدون HyperRAM و UART | داده خام خط پایدار و قابل بازسازی باشد | Capture، لبه نمونه‌برداری یا بسته‌بندی پیکسل |
| 4 | اعتبارسنجی FIFO و CDC | هیچ overflow/underflow رخ ندهد؛ تعداد ورودی و خروجی برابر باشد | اختلاف کلاک، handshake یا ظرفیت/سرویس‌دهی FIFO |
| 5 | اعتبارسنجی HyperRAM مستقل از دوربین | الگوی نوشتن/خواندن و CRC یکسان باشد؛ init_calib معتبر باشد | کالیبراسیون، burst، آدرس‌دهی، arbitration یا timing حافظه |
| 6 | اعتبارسنجی UART و MATLAB | تعداد بایت، ترتیب بایت، طول payload و CRC با FPGA برابر باشد | framing، parser، endian یا دریافت ناقص میزبان |

### تمایز امضای بصری خطاها

- **هاله سبز/بنفش یا رنگ کلی غلط با هندسه سالم:** ابتدا ترتیب YUV422 و سپس قرارداد RGB565/Endian بررسی شود.
- **رنگ‌های شدیداً اشباع‌شده پس از یک نقطه از تصویر:** احتمال از دست رفتن یک بایت و جابه‌جایی فاز متوالی، یا خطای burst/descriptor مطرح است.
- **نوارهای عمودی یا ستون‌های یکی‌درمیان:** byte-phase، زوج/فرد بودن تعداد بایت و reset فاز در انتهای هر HREF بررسی شود.
- **نوارهای افقی، خطوط تکراری/حذف‌شده یا tearing:** طول هر خط، overflow FIFO، سرویس‌دهی HyperRAM و مرزبندی فریم بررسی شود.
- **پوستریزه‌شدن شدید:** ابتدا قالب خروجی، بیت 7 رجیستر `0x24`، جابه‌جایی/حذف بیت‌ها و packing بررسی شود؛ کوانتیزه‌سازی ذاتی RGB565 معمولاً فقط banding خفیف در گرادیان‌های نرم ایجاد می‌کند.
- **خرابی فقط پس از انتقال به PC:** مسیر HyperRAM/UART/MATLAB از مسیر Capture جداگانه آزمایش شود.

### نکات نیازمند تطبیق پیش از تبدیل به «واقعیت قطعی»

گزارش‌های مکمل در برخی جزئیات سطح اطمینان یکسان ندارند. مواردی مانند نرخ/پهنای‌باند مؤثر HyperRAM، مقدار دقیق فرکانس مجاز، تفسیر بعضی بیت‌های رجیستر، شماره چیپ‌آیدی در نسخه‌های مختلف دیتاشیت، و ادعاهای مبتنی بر تجربه پلتفرم‌های دیگر باید با دیتاشیت دقیق قطعه، نسخه IP و اندازه‌گیری روی برد تطبیق داده شوند. تجربه ESP32/PSRAM یا SDRAM شاهد مکانیزم عمومی است، نه اثبات اینکه همان خطا در HyperRAM این برد رخ داده است.

**قاعده تصمیم‌گیری:** تا وقتی ثبت خام BRAM از یک خط تصویر سالم نشده، تغییر هم‌زمان در HyperRAM، UART و MATLAB انجام نشود. هر لایه پس از اثبات لایه قبلی وارد زنجیره شود.

---

# بررسی فنی رابط دوربین GC0308 با FPGA و عیب‌یابی تخریب تصویر

> **نوع سند:** گزارش پژوهشی فنی  
> **تاریخ:** 2026-11-19  
> **هدف سخت‌افزاری:** Sipeed Tang Nano 4K / Gowin GW1NSR-LV4CQN48P  
> **سنسور:** GalaxyCore GC0308  
> **پیاده‌سازی:** VHDL، HyperRAM، UART و MATLAB  
> **زبان گزارش:** فارسی

---

## فهرست مطالب

1. [خلاصه مدیریتی](#1-خلاصه-مدیریتی)
2. [محدوده و سطح اعتبار شواهد](#2-محدوده-و-سطح-اعتبار-شواهد)
3. [معماری و فرمت‌های خروجی GC0308](#3-معماری-و-فرمتهای-خروجی-gc0308)
4. [رجیسترهای مهم سنسور](#4-رجیسترهای-مهم-سنسور)
5. [Timing و رابط DVP](#5-timing-و-رابط-dvp)
6. [گزارش‌های واقعی خطا و تجربیات مهندسی](#6-گزارشهای-واقعی-خطا-و-تجربیات-مهندسی)
7. [RGB565، YUV422 و Grayscale](#7-rgb565-yuv422-و-grayscale)
8. [FIFO و حافظه خارجی](#8-fifo-و-حافظه-خارجی)
9. [پروژه‌ها و درایورهای مرجع](#9-پروژهها-و-درایورهای-مرجع)
10. [رتبه‌بندی علت‌های محتمل در پروژه Tang Nano 4K](#10-رتبهبندی-علتهای-محتمل-در-پروژه-tang-nano-4k)
11. [برنامه پیشنهادی عیب‌یابی](#11-برنامه-پیشنهادی-عیبیابی)
12. [پایش سلامت فریم](#12-پایش-سلامت-فریم)
13. [محدودیت‌ها و موارد حل‌نشده](#13-محدودیتها-و-موارد-حلنشده)
14. [منابع مستقیم](#14-منابع-مستقیم)

---

# 1. خلاصه مدیریتی

هدف این گزارش شناسایی منشأ تخریب تصویر در زنجیره زیر است:

```text
GC0308
  |
  v
FPGA Camera Capture
  |
  v
Pixel Processing / Packing
  |
  v
Input FIFO
  |
  v
HyperRAM Frame Buffer
  |
  v
Output FIFO
  |
  v
UART
  |
  v
MATLAB Reconstruction
```

مسئله‌های مورد توجه عبارت‌اند از posterization، تغییر رنگ، نوارهای افقی و عمودی، جابه‌جایی بایت‌ها، خطای شمارش پیکسل، از دست رفتن داده، و اشکال در هم‌زمان‌سازی.

## 1.1 مهم‌ترین نتایج

1. **GC0308 چند ترتیب مختلف برای YUV422 دارد.** انتخاب ترتیب اشتباه در FPGA یا MATLAB می‌تواند رنگ را خراب کند، درحالی‌که ابعاد هندسی تصویر ظاهراً درست باقی می‌ماند.
2. **درایور Linux برای GC0308 فرمت‌های YUV422 را به‌صورت صریح به مقادیر رجیستر خروجی نگاشت می‌کند.** این نگاشت مرجع مناسبی برای تطبیق تنظیمات سنسور است.
3. **RGB565 در درایور Linux با ترتیب Big-Endian روی گذرگاه دو بایتی معرفی شده است.** قرارداد بایت در FPGA و MATLAB باید دقیقاً یکسان باشد.
4. **یک گزارش واقعی GC0308 روی ESP32-S3، خرابی تصویر را به مسیر DMA/PSRAM نسبت می‌دهد.** این گزارش نشان می‌دهد که طول فریم گزارش‌شده لزوماً اثبات نمی‌کند تمام داده‌ها واقعاً دریافت شده‌اند.
5. **برای پروژه Tang Nano 4K هنوز علت خرابی اثبات نشده است.** در حال حاضر باید Capture، Packing، FIFO، HyperRAM و MATLAB را جداگانه اعتبارسنجی کرد.
6. در منابع عمومی بررسی‌شده، نمونه‌ای با شواهد کامل و قابل بازتولید که دقیقاً GC0308 + Tang Nano 4K + HyperRAM + VHDL را پیاده‌سازی کرده باشد، پیدا نشد.

## 1.2 رتبه‌بندی اولیه فرضیه‌ها

| اولویت | فرضیه | دلیل |
|---:|---|---|
| 1 | Pixel packing و byte alignment | تغییرات قبلی RGB888 به RGB565 و بازآرایی مسیر داده |
| 2 | FIFO synchronization / rate mismatch | اختلاف کلاک دوربین و حافظه و احتمال خطای handshake |
| 3 | HyperRAM write/read integrity | احتمال تخریب یا جابه‌جایی داده در ذخیره‌سازی و بازیابی |
| 4 | YUV422 byte ordering | GC0308 چند ترتیب خروجی YUV422 دارد |
| 5 | PCLK sampling edge | نمونه‌برداری خارج از پنجره معتبر داده |
| 6 | HREF/VSYNC interpretation | خطا در مرزبندی خطوط و فریم |
| 7 | Sensor register configuration | تنظیم نادرست فرمت یا Timing |
| 8 | RGB565 quantization | به‌تنهایی توضیح کافی برای خرابی شدید و ساختاری نیست |

این جدول **رتبه‌بندی فرضیه‌ها** است، نه تشخیص قطعی.

---

# 2. محدوده و سطح اعتبار شواهد

برای جلوگیری از تعمیم نادرست، یافته‌ها در چهار گروه قرار می‌گیرند:

| برچسب | معنی |
|---|---|
| **GC0308-specific** | مستندات یا کد مشخصاً مربوط به GC0308 |
| **Related sensor** | تجربه سنسور مشابه؛ قابل تعمیم مستقیم نیست |
| **General FPGA** | اصل عمومی طراحی رابط دوربین، FIFO یا حافظه |
| **Engineering analysis** | تحلیل فنی یا فرضیه‌ای که برای پروژه حاضر باید آزمایش شود |

همچنین سه سطح اعتبار در نظر گرفته شده است:

- **مستند:** در دیتاشیت یا کد درایور قابل مشاهده است.
- **گزارش تجربی:** مهندس نتیجه آزمایش را در Issue، PR یا گزارش پروژه منتشر کرده است.
- **تحلیل:** توضیح فنی محتمل است، اما برای همین سخت‌افزار آزمایش مستقیم نشده است.

> نکته روش‌شناختی: وجود یک رجیستر در دیتاشیت، اثبات نمی‌کند که مقدار آن در ماژول فعلی درست تنظیم شده است. همچنین وجود یک پروژه FPGA بدون سورس HDL قابل بررسی، اثبات صحت جزئیات پیاده‌سازی آن نیست.

---

# 3. معماری و فرمت‌های خروجی GC0308

GC0308 یک سنسور VGA با رابط موازی DVP هشت‌بیتی است. مسیر کلی داده در حالت‌های پردازش‌شده به شکل زیر است:

```text
Pixel Array
    |
    v
Analog Front End / ADC
    |
    v
Image Signal Processing
    |
    +--> White Balance
    +--> Color Processing
    +--> Gamma / Image Enhancement
    |
    v
Output Format Selection
    |
    +--> RGB565
    +--> YCbCr422
    +--> Other supported modes
    |
    v
8-bit DVP Interface
```

برای جزئیات دقیق باید به دیتاشیت GC0308 و درایور مختص همین سنسور مراجعه کرد؛ مستندات GC0309، GC0328 یا OV7670 جایگزین دیتاشیت GC0308 نیستند.

## 3.1 مشخصات کلی رابط

| پارامتر | مقدار / توضیح |
|---|---|
| رزولوشن VGA | 640×480 |
| رابط داده | DVP موازی 8-bit |
| کلاک پیکسل | PCLK |
| هم‌زمان‌سازی افقی | HSYNC/HREF، مطابق پیکربندی و نام‌گذاری ماژول |
| هم‌زمان‌سازی عمودی | VSYNC |
| رابط پیکربندی | Two-wire serial interface |
| فرمت‌های مورد بررسی | RGB565، YCbCr422 و حالت‌های تک‌کاناله |

مقادیر الکتریکی، محدوده فرکانس و Timing نهایی باید از نسخه دیتاشیت و مشخصات ماژول دوربین استخراج شوند؛ مقدار XCLK یا PCLK را نباید بدون بررسی پیکربندی و Timing به‌صورت ثابت فرض کرد.

---

# 4. رجیسترهای مهم سنسور

## 4.1 رجیستر انتخاب فرمت: Page 0، آدرس 0x24

در دیتاشیت GC0308، فیلد پایین رجیستر `0x24` برای انتخاب فرمت خروجی استفاده می‌شود. مقادیر زیر به‌عنوان مقادیر فیلد فرمت گزارش شده‌اند؛ هنگام نوشتن رجیستر کامل، سایر بیت‌ها نیز باید مطابق دیتاشیت حفظ یا مقداردهی شوند.

| مقدار فیلد [4:0] | ترتیب خروجی |
|---|---|
| `00000` | Cb Y Cr Y |
| `00001` | Cr Y Cb Y |
| `00010` | Y Cb Y Cr |
| `00011` | Y Cr Y Cb |
| `00110` | RGB565 |
| `00111` | RGB555 |
| `01001` | RGB444 |
| `10001` | Only Y |
| `10010` | Only Cb |
| `10011` | Only Cr |
| `10100` | Only R |
| `10101` | Only G |
| `10110` | Only B |

درایور Linux نگاشت زیر را برای فرمت‌های YUV و RGB به‌کار می‌برد:

| Linux Media Bus Format | مقدار فیلد خروجی |
|---|---:|
| `MEDIA_BUS_FMT_UYVY8_2X8` | `0x00` |
| `MEDIA_BUS_FMT_VYUY8_2X8` | `0x01` |
| `MEDIA_BUS_FMT_YUYV8_2X8` | `0x02` |
| `MEDIA_BUS_FMT_YVYU8_2X8` | `0x03` |
| `MEDIA_BUS_FMT_RGB565_2X8_BE` | `0x06` |

منبع کد:
[Linux Kernel — gc0308.c](https://github.com/torvalds/linux/blob/master/drivers/media/i2c/gc0308.c)

## 4.2 رجیستر کنترل خروجی: Page 0، آدرس 0x25

این رجیستر در کنترل فعال‌سازی سیگنال‌های خروجی نقش دارد. بیت‌های مربوط به Data Enable، PCLK Enable، HSYNC Enable و VSYNC Enable باید با نسخه دیتاشیت تطبیق داده شوند.

## 4.3 رجیستر کنترل هم‌زمان‌سازی: Page 0، آدرس 0x26

رجیستر `0x26` شامل کنترل‌هایی مرتبط با موارد زیر است:

- تأخیر داده و HSYNC
- رفتار PCLK اطراف سیگنال‌های Sync
- گیت‌کردن PCLK در blanking
- قطبیت PCLK
- قطبیت HSYNC
- قطبیت VSYNC

برای طراحی FPGA باید مقدار واقعی این رجیستر خوانده یا از توالی initialization استخراج شود. فرض‌کردن قطبیت سیگنال‌ها بر اساس نام آن‌ها کافی نیست.

## 4.4 رجیسترهای پردازش تصویر

رجیسترهای زیر در مستندات و درایور GC0308 برای کنترل بخش‌هایی از پردازش تصویر دیده می‌شوند. تفسیر دقیق هر بیت و صفحه رجیستر باید از دیتاشیت و سورس درایور انجام شود.

| آدرس / محدوده | کاربرد کلی |
|---|---|
| `0x20–0x23` | کنترل بلوک‌های ISP و حالت‌های ویژه |
| `0x50` | Gain |
| `0x53–0x5C` | Gain و پارامترهای مرتبط با کانال‌های رنگ و AWB |
| `0x72–0x7C` | Interpolation و Edge Enhancement |
| `0x93–0x98` | Color Correction Matrix |
| `0x9F–0xAF` | Gamma |
| `0xB0–0xB2` | Saturation |
| `0xB3–0xB5` | Contrast و Luma Offset |
| `0xD0–0xD3` | کنترل‌های مرتبط با AEC |

**هشدار:** جدول بالا خلاصه کاربردی است، نه جایگزین جدول بیت‌به‌بیت دیتاشیت. قبل از تغییر رجیسترها باید Page Selection و مقدار اولیه هر رجیستر ثبت شود.

---

# 5. Timing و رابط DVP

## 5.1 سیگنال‌های اصلی

| سیگنال | کاربرد |
|---|---|
| D[7:0] | داده موازی |
| PCLK | کلاک داده خروجی |
| HSYNC/HREF | تعیین ناحیه یا زمان فعال خط، بسته به پیکربندی |
| VSYNC | هم‌زمان‌سازی فریم |
| XCLK/CLKIN | کلاک ورودی سنسور |
| SCL/SDA | پیکربندی سنسور |

در برخی ماژول‌ها نام HREF استفاده می‌شود و در بعضی اسناد HSYNC. باید شکل موج و معنای سیگنال در دیتاشیت همان قطعه بررسی شود.

## 5.2 شمارش داده برای VGA

برای RGB565 و YUV422، در هر پیکسل به‌طور متوسط دو بایت منتقل می‌شود:

[
N_{	ext{bytes/line}} = 640 	imes 2 = 1280
]

[
N_{	ext{frame}} = 640 	imes 480 	imes 2 = 614400 	ext{bytes}
]

برای Grayscale هشت‌بیتی:

[
N_{	ext{frame,gray}} = 640 	imes 480 = 307200 	ext{bytes}
]

این اعداد، تعداد داده فعال تصویر هستند؛ blanking و کلاک‌های خارج از ناحیه فعال در آن‌ها شمرده نشده‌اند.

## 5.3 تست Timing پیشنهادی

در هر خط فعال، شمارنده بایت را از اولین نمونه معتبر HREF تا پایان خط افزایش دهید. در پایان خط، مقدار شمارنده را ذخیره کنید.

معیار اولیه برای RGB565/YUV422:

```text
Expected active bytes per line = 1280
Expected active lines per frame = 480
Expected frame bytes = 614400
```

به‌جای اعتماد به شمارنده کلی فریم، توزیع طول خطوط را نیز بررسی کنید. ممکن است مجموع بایت‌ها درست باشد اما یک خط کوتاه و خط دیگر بلند باشد.

---

# 6. گزارش‌های واقعی خطا و تجربیات مهندسی

## 6.1 تخریب تصویر GC0308 در مسیر DMA/PSRAM

**طبقه‌بندی:** GC0308-specific، گزارش تجربی  
**منبع اصلی:** [xiaozhi-esp32 Issue #2294](https://github.com/78/xiaozhi-esp32/issues/2294)

در این گزارش، GC0308 روی ESP32-S3 با خروجی RGB565 استفاده شده است. گزارش‌دهنده خرابی رنگ و آرتیفکت‌های تصویری را مشاهده کرده و مشکل را به مسیر DMA/PSRAM نسبت داده است.

نکته مهم گزارش این است که طول فریم گزارش‌شده می‌توانست برابر طول مورد انتظار باشد، درحالی‌که کامل‌بودن واقعی داده انتقال‌یافته تضمین نشده بود.

راهکار گزارش‌شده شامل غیرفعال‌کردن مسیر PSRAM DMA و استفاده از بافر واسط در SRAM داخلی بود. گزارش‌دهنده پس از تغییر، دریافت چند فریم متوالی بدون خرابی را ثبت کرده است.

**ارتباط با پروژه Tang Nano:** این گزارش اثبات نمی‌کند HyperRAM یا FIFO پروژه ما همین خطا را دارند؛ اما نشان می‌دهد طول فریم به‌تنهایی معیار کافی برای سلامت داده نیست. باید تعداد داده‌های واقعاً نوشته و خوانده‌شده و یکپارچگی محتوا بررسی شود.

## 6.2 اصلاح عمومی تشخیص فریم ناقص در ESP32 Camera

- [Issue #867](https://github.com/espressif/esp32-camera/issues/867)
- [Pull Request #868](https://github.com/espressif/esp32-camera/pull/868)

این مورد یک تجربه مرتبط با مسیر DMA در درایور ESP32 Camera است. اصلاح پیشنهادی/ادغام‌شده بر بررسی تعداد Descriptorهای تکمیل‌شده و طول واقعی داده نوشته‌شده تکیه دارد و از تحویل فریم ناقص به لایه بالاتر جلوگیری می‌کند.

**محدودیت تعمیم:** این Issue/PR را نباید بدون بررسی متن و نسخه درایور به‌عنوان اثبات همان اشکال در FPGA یا HyperRAM معرفی کرد. ارزش آن در اصل طراحی است: فریم ناقص باید تشخیص داده شود و به‌عنوان فریم سالم تحویل داده نشود.

## 6.3 جابه‌جایی بایت RGB565

**طبقه‌بندی:** General image pipeline  
**منبع:** [esp32-camera Issue #422](https://github.com/espressif/esp32-camera/issues/422)

این بحث به ناسازگاری ترتیب بایت RGB565 در یک مسیر پردازش تصویر مربوط است. راهکار مطرح‌شده جابه‌جایی دو بایت هر پیکسل بود.

این مورد شاهدی درباره خطای اختصاصی GC0308 نیست؛ اما اهمیت قرارداد Endianness را نشان می‌دهد.

برای مثال، اگر FPGA مقدار 16 بیتی را به ترتیب زیر بفرستد:

```text
Byte 0 = pixel[15:8]
Byte 1 = pixel[7:0]
```

MATLAB باید دقیقاً همین ترتیب را اعمال کند. جابه‌جایی دو بایت، مقدار RGB565 و در نتیجه رنگ را تغییر می‌دهد.

## 6.4 سیم‌بندی اشتباه بیت‌های رنگ در پروژه FPGA

**طبقه‌بندی:** General FPGA camera interface  
**منبع:** [ECE3400 Team 14 — Lab 4](https://ece3400-team14.github.io/Team-14-Website/Labs/Lab4.html)

این گزارش آزمایشگاهی مشکلاتی در بازسازی رنگ را شرح می‌دهد که بررسی سیم‌بندی بیت‌های داده در تشخیص آن مؤثر بوده است.

درس قابل استفاده: قبل از تغییر الگوریتم RGB565 یا اعمال اصلاحات نرم‌افزاری رنگ، نگاشت فیزیکی D[7:0] و ترتیب بیت‌ها باید با الگوی معلوم بررسی شود.

## 6.5 اختلاف نرخ FIFO

**طبقه‌بندی:** General FPGA / Machine Vision  
**منبع:** [NI Community — FPGA FIFO discussion](https://forums.ni.com/t5/Machine-Vision/1473R-FPGA/td-p/3232853)

این بحث نمونه‌ای از مشکل اختلاف نرخ تولید و مصرف داده در مسیر دوربین و FIFO است.

اصل طراحی:

[
R_{	ext{write,avg}} > R_{	ext{read,avg}}
]

به معنی آن است که FIFO در نهایت سرریز می‌شود؛ افزایش عمق FIFO تنها زمان وقوع سرریز را عقب می‌اندازد، نه اینکه اختلاف نرخ متوسط را حل کند.

راهکار باید نرخ تولید، نرخ مصرف، دوره‌های عدم سرویس و ظرفیت بافر را هم‌زمان در نظر بگیرد.

---

# 7. RGB565، YUV422 و Grayscale

## 7.1 RGB565

ساختار هر پیکسل:

```text
15          11 10           5 4            0
+-------------+--------------+--------------+
|   R[4:0]    |   G[5:0]     |   B[4:0]     |
+-------------+--------------+--------------+
```

حجم فریم VGA:

[
640 	imes 480 	imes 2 = 614400 	ext{bytes}
]

درایور Linux فرمت `MEDIA_BUS_FMT_RGB565_2X8_BE` را برای GC0308 ثبت می‌کند. در قرارداد Big-Endian، بایت اول شامل بیت‌های بالایی پیکسل است.

RGB565 نسبت به RGB888 تعداد سطوح کانال‌های رنگ را کاهش می‌دهد، اما این کاهش به‌تنهایی معمولاً توضیح مناسبی برای نوارهای ساختاری شدید، جابه‌جایی خطوط یا تخریب دوره‌ای داده نیست.

## 7.2 YUV422

در YUV422 هر دو پیکسل مجاور اطلاعات chroma مشترک دارند و برای هر پیکسل یک نمونه luma منتقل می‌شود.

چهار ترتیب مستندشده برای GC0308:

| مقدار فیلد | Byte 0 | Byte 1 | Byte 2 | Byte 3 |
|---|---|---|---|---|
| `0x00` | Cb | Y0 | Cr | Y1 |
| `0x01` | Cr | Y0 | Cb | Y1 |
| `0x02` | Y0 | Cb | Y1 | Cr |
| `0x03` | Y0 | Cr | Y1 | Cb |

در حالت `0x02`، ترتیب معادل YUYV است:

```text
Y0 Cb Y1 Cr
```

اگر MATLAB ترتیب دیگری فرض کند، رنگ‌ها نادرست خواهند شد؛ حتی اگر طول فریم و ابعاد تصویر صحیح باشند.

## 7.3 Grayscale

در صورت استفاده از خروجی Only Y، مسیر بازسازی ساده‌تر می‌شود و وابستگی به ترتیب Cb/Cr از بین می‌رود.

برای داده YUYV نیز می‌توان نمونه‌های Y را از بایت‌های اول و سوم هر گروه چهار‌بایتی استخراج کرد:

```text
Y0 Cb Y1 Cr
 |     |
 v     v
Gray0 Gray1
```

اگر خروجی Grayscale نیز نوارهای مشابه داشته باشد، فرضیه خطای صرفاً chroma ordering ضعیف‌تر می‌شود.

## 7.4 مقایسه

| ویژگی | RGB565 | YUV422 | Grayscale 8-bit |
|---|---:|---:|---:|
| متوسط بیت بر پیکسل | 16 | 16 | 8 |
| حجم VGA | 614400 B | 614400 B | 307200 B |
| بازسازی رنگ | مستقیم | نیازمند تبدیل | ندارد |
| حساسیت به ترتیب بایت | زیاد | زیاد | کمتر |
| کاربرد تشخیصی | تست مسیر RGB | تست ترتیب chroma | جداسازی luma از chroma |

---

# 8. FIFO و حافظه خارجی

## 8.1 نرخ داده

برای VGA در RGB565 یا YUV422:

[
614400 	ext{bytes/frame}
]

در 30 فریم بر ثانیه:

[
614400 	imes 30 = 18.432 	ext{MB/s}
]

این نرخ متوسط داده فعال فریم است. نرخ لحظه‌ای هنگام فعال بودن خط ممکن است بیشتر باشد؛ بنابراین طراحی FIFO باید با نرخ burst و تأخیر سرویس حافظه بررسی شود.

## 8.2 ظرفیت FIFO

اگر ورودی با نرخ (R) بایت بر ثانیه داده تولید کند و حافظه حداکثر برای مدت (T) سرویس ندهد:

[
D_{	ext{FIFO}} ge R 	imes T
]

برای مثال، در نرخ 20 MB/s و تأخیر 100 µs:

[
D ge 20 	imes 10^6 	imes 100 	imes 10^{-6}
= 2000 	ext{bytes}
]

این مقدار فقط حد نظری اولیه است؛ باید حاشیه اطمینان، عمق burst، latency کنترل‌کننده و رفتار Full/Empty نیز لحاظ شوند.

## 8.3 شمارنده‌های لازم

حداقل شمارنده‌های زیر پیشنهاد می‌شوند:

```text
capture_byte_count
capture_line_count
input_fifo_write_count
input_fifo_read_count
input_fifo_overflow_count
input_fifo_underflow_count
hyperram_write_count
hyperram_read_count
output_fifo_overflow_count
output_fifo_underflow_count
```

در پایان یک فریم که تمام داده‌ها تخلیه شده‌اند، باید تعداد داده‌های نوشته‌شده و خوانده‌شده در هر مرز مورد انتظار برابر باشد.

## 8.4 تست مستقل HyperRAM

قبل از اتصال دوربین، حافظه باید با الگوهای معلوم آزمایش شود:

```text
0x00000000
0xFFFFFFFF
0xAAAAAAAA
0x55555555
0x12345678
```

مسیر تست:

```text
Pattern Generator
      |
      v
HyperRAM Write
      |
      v
HyperRAM Read
      |
      v
Comparator
      |
      v
Error Counter / First Error Address
```

گزارش تست باید شامل تعداد کلمات، تعداد mismatch، اولین آدرس خطا، مقدار مورد انتظار و مقدار خوانده‌شده باشد.

---

# 9. پروژه‌ها و درایورهای مرجع

## 9.1 Linux Kernel GC0308 Driver

[سورس درایور GC0308 در Linux Kernel](https://github.com/torvalds/linux/blob/master/drivers/media/i2c/gc0308.c)

کاربردها:

- مشاهده نگاشت فرمت‌های Media Bus به رجیستر سنسور
- بررسی تنظیمات فرمت خروجی
- مشاهده توالی رجیسترها
- بررسی کنترل‌های استاندارد دوربین

این یکی از مهم‌ترین منابع نرم‌افزاری برای تطبیق رفتار GC0308 است.

## 9.2 Espressif ESP32 Camera

- [درایور GC0308](https://github.com/espressif/esp32-camera/blob/master/sensors/gc0308.c)
- [تعاریف رجیستر GC0308](https://github.com/espressif/esp32-camera/blob/master/sensors/private_include/gc0308_regs.h)
- [تنظیمات GC0308](https://github.com/espressif/esp32-camera/blob/master/sensors/private_include/gc0308_settings.h)
- [مخزن اصلی esp32-camera](https://github.com/espressif/esp32-camera)

این کدها برای مقایسه توالی initialization و فرمت‌های خروجی مفیدند؛ اما پیکربندی ESP32 را نباید بدون تطبیق با برد و Timing خودمان عیناً کپی کرد.

## 9.3 NuttX GC0308

[NuttX — مستندات برد LCKFB-SZPI-ESP32S3](https://nuttx.apache.org/docs/latest/platforms/xtensa/esp32s3/boards/lckfb-szpi-esp32s3/index.html)

برای بررسی یکپارچه‌سازی GC0308 در یک پلتفرم Embedded مفید است. این مرجع، نمونه FPGA نیست.

## 9.4 مستندات ماژول Cam0308

[M5Stack Cam0308 Documentation](https://docs.m5stack.com/en/stamp/Stamp-AddOn_Cam0308)

برای مشخصات ماژول و اتصال فیزیکی مفید است. مشخصات ماژول باید با ماژول واقعی مورد استفاده در پروژه تطبیق داده شود.

## 9.5 پروژه FPGA گزارش‌شده با GC0308

[پروژه FPGA مبتنی بر GC0308 و FDMA](https://icode.best/i/440833415982333)

این منبع یک نمونه پروژه FPGA با GC0308 و Frame Buffer را معرفی می‌کند. با این حال، در منبع قابل بررسی، سورس کامل HDL و جزئیات کافی برای تأیید لبه PCLK، منطق FIFO یا توالی دقیق حافظه در دسترس نبود. بنابراین باید آن را نمونه پروژه گزارش‌شده دانست، نه Reference Design کاملاً قابل بازتولید.

---

# 10. رتبه‌بندی علت‌های محتمل در پروژه Tang Nano 4K

با توجه به تغییرات قبلی پروژه بین RGB888، RGB565 و YUV422، پیشنهاد می‌شود بررسی به ترتیب زیر انجام شود:

| رتبه | عامل | تست تفکیک‌کننده |
|---:|---|---|
| 1 | Pixel packing / byte alignment | ذخیره و ارسال داده Capture بدون HyperRAM |
| 2 | FIFO synchronization | شمارنده مستقل write/read و overflow/underflow |
| 3 | HyperRAM integrity | نوشتن/خواندن الگو و CRC |
| 4 | YUV422 ordering | ثبت چند بایت خام و مقایسه با رجیستر 0x24 |
| 5 | PCLK edge | بررسی شکل موج D[7:0] نسبت به PCLK |
| 6 | HREF/VSYNC | شمارش بایت هر خط و خطوط هر فریم |
| 7 | Sensor initialization | خواندن و ثبت رجیسترهای مؤثر |
| 8 | RGB565 quantization | مقایسه با داده مرجع و بررسی هیستوگرام کانال‌ها |

---

# 11. برنامه پیشنهادی عیب‌یابی

## مرحله 1 — تثبیت سنسور

- Chip ID را بخوانید و ثبت کنید.
- Page و رجیسترهای مؤثر را ثبت کنید.
- مقدار رجیستر `0x24` را کنترل کنید.
- مقدار رجیسترهای `0x25` و `0x26` را ثبت کنید.
- رزولوشن و قطبیت Sync را از شکل موج تأیید کنید.

## مرحله 2 — اعتبارسنجی Capture

بدون Pixel Processing پیچیده، داده خام D[7:0] را ثبت کنید.

برای هر خط:

- تعداد نمونه‌های معتبر
- طول خط
- تعداد خطوط فریم
- تعداد کل بایت‌ها

را ذخیره کنید.

برای VGA و RGB565/YUV422 انتظار اولیه 1280 بایت فعال در هر خط و 480 خط فعال است.

## مرحله 3 — اعتبارسنجی Packing با BRAM

HyperRAM را موقتاً از مسیر حذف کنید:

```text
GC0308 -> Capture -> Packer -> BRAM -> UART -> MATLAB
```

اگر تصویر در این مرحله خراب است، علت در Sensor/Capture/Packing یا MATLAB قرار دارد، نه HyperRAM.

## مرحله 4 — اعتبارسنجی HyperRAM مستقل

ابتدا الگوهای ثابت را بنویسید و بخوانید. پس از صفر شدن خطاهای Readback، فریم دوربین را وارد مسیر حافظه کنید.

## مرحله 5 — اعتبارسنجی مسیر UART

پروتکل انتقال باید حداقل شامل موارد زیر باشد:

```text
Frame Header
Frame ID
Pixel Format
Frame Length
Frame Payload
Frame CRC32
Frame Status
```

MATLAB باید Header، طول فریم و CRC را بررسی کند و فریم نامعتبر را به‌عنوان تصویر سالم نمایش ندهد.

## مرحله 6 — بازگشت به YUV422

پس از تثبیت RGB565، مسیر YUV422 را جداگانه فعال کنید. ترتیب بایت خروجی باید از رجیستر `0x24` و درایور GC0308 استخراج شود و در کد MATLAB نیز همان قرارداد اعمال شود.

---

# 12. پایش سلامت فریم

پیشنهاد می‌شود هر فریم همراه با گزارش سلامت به MATLAB ارسال شود.

## 12.1 شمارنده‌های پیشنهادی

| شمارنده | کاربرد |
|---|---|
| `captured_lines` | تعداد خطوط دریافت‌شده |
| `captured_pixels` | تعداد پیکسل‌های دریافت‌شده |
| `captured_bytes` | تعداد بایت‌های Capture |
| `short_line_count` | تعداد خطوط کوتاه |
| `long_line_count` | تعداد خطوط بلند |
| `invalid_sync_count` | خطاهای Sync |
| `input_fifo_overflow` | سرریز FIFO ورودی |
| `input_fifo_underflow` | کم‌خوانی FIFO ورودی |
| `hyperram_write_count` | تعداد داده‌های نوشته‌شده |
| `hyperram_read_count` | تعداد داده‌های خوانده‌شده |
| `hyperram_mismatch_count` | تعداد اختلاف‌های Readback |
| `output_fifo_overflow` | سرریز FIFO خروجی |
| `output_fifo_underflow` | کم‌خوانی FIFO خروجی |
| `capture_crc32` | CRC داده پس از Capture |
| `readback_crc32` | CRC داده پس از بازیابی حافظه |
| `frame_status` | وضعیت نهایی فریم |

## 12.2 کدهای وضعیت پیشنهادی

| Code | Status |
|---|---|
| `0x00` | FRAME_OK |
| `0x01` | CAPTURE_ERROR |
| `0x02` | LINE_LENGTH_ERROR |
| `0x03` | FIFO_OVERFLOW |
| `0x04` | FIFO_UNDERFLOW |
| `0x05` | HYPERRAM_WRITE_ERROR |
| `0x06` | HYPERRAM_READ_ERROR |
| `0x07` | CRC_ERROR |
| `0x08` | UART_TRANSFER_ERROR |

## 12.3 تفسیر CRC

دو CRC مستقل مفید است:

- `capture_crc32`: پس از Capture و Packing
- `readback_crc32`: پس از بازیابی همان فریم از HyperRAM

اگر CRCها برابر باشند، شواهد خوبی از سلامت مسیر حافظه داریم؛ اما این برابری صحت داده اولیه سنسور را اثبات نمی‌کند. ممکن است داده از ابتدا اشتباه نمونه‌برداری شده باشد و همان داده اشتباه بدون تغییر ذخیره و بازیابی شود.

برای تشخیص خطای UART نیز بهتر است MATLAB CRC payload دریافتی را مستقلاً محاسبه کند.

---

# 13. محدودیت‌ها و موارد حل‌نشده

| موضوع | وضعیت |
|---|---|
| پشتیبانی GC0308 از RGB565 | مستند |
| پشتیبانی GC0308 از YUV422 | مستند |
| چهار ترتیب YUV422 | در دیتاشیت/درایور قابل بررسی |
| نگاشت RGB565 در Linux | درایور Big-Endian را معرفی می‌کند |
| کنترل قطبیت Sync | در رجیسترهای سنسور مستند |
| خرابی تصویر GC0308 در مسیر DMA/PSRAM | گزارش تجربی موجود |
| اصلاح تشخیص فریم ناقص در ESP32 Camera | Issue/PR قابل بررسی |
| نمونه FPGA با GC0308 | پروژه گزارش‌شده پیدا شده |
| سورس کامل و قابل بازتولید FPGA پروژه فوق | در منبع بررسی‌شده تأیید نشد |
| پیاده‌سازی عمومی GC0308 روی Tang Nano 4K | پیدا نشد |
| پیاده‌سازی عمومی GC0308 + HyperRAM | پیدا نشد |
| علت دقیق posterization پروژه حاضر | اثبات نشده |
| علت دقیق نوارهای ساختاری پروژه حاضر | اثبات نشده |

---

# 14. منابع مستقیم

## 14.1 دیتاشیت و مستندات سنسور

1. [GC0308 Datasheet — PDF mirror](https://min.at/prinz/fp-content/attachs/GC0308.pdf)
2. [GC0308 Datasheet — Kamami mirror](https://download.kamami.pl/p1186498-GC0308.pdf)
3. [Camemaker — GC0308 documentation](https://www.camemaker.com/shop/gc0308-galaxycore-gc0308-0-30mp-fsi-rolling-30fps-2137/document/193)

> نسخه دیتاشیت و شماره بازنگری را پیش از استفاده برای طراحی نهایی کنترل کنید.

## 14.2 درایورها و سورس کد

1. [Linux Kernel — gc0308.c](https://github.com/torvalds/linux/blob/master/drivers/media/i2c/gc0308.c)
2. [Espressif — gc0308.c](https://github.com/espressif/esp32-camera/blob/master/sensors/gc0308.c)
3. [Espressif — gc0308_regs.h](https://github.com/espressif/esp32-camera/blob/master/sensors/private_include/gc0308_regs.h)
4. [Espressif — gc0308_settings.h](https://github.com/espressif/esp32-camera/blob/master/sensors/private_include/gc0308_settings.h)
5. [ESP32 Camera repository](https://github.com/espressif/esp32-camera)

## 14.3 گزارش‌های خطا و تجربیات مهندسی

1. [xiaozhi-esp32 Issue #2294 — GC0308 RGB565 corruption](https://github.com/78/xiaozhi-esp32/issues/2294)
2. [esp32-camera Issue #867 — DMA frame integrity](https://github.com/espressif/esp32-camera/issues/867)
3. [esp32-camera PR #868 — incomplete DMA frame handling](https://github.com/espressif/esp32-camera/pull/868)
4. [esp32-camera Issue #422 — RGB565 byte order](https://github.com/espressif/esp32-camera/issues/422)
5. [esp32-camera Issue #775 — PSRAM DMA/JPEG discussion](https://github.com/espressif/esp32-camera/issues/775)
6. [ECE3400 Team 14 — FPGA camera lab](https://ece3400-team14.github.io/Team-14-Website/Labs/Lab4.html)
7. [NI Community — FPGA FIFO discussion](https://forums.ni.com/t5/Machine-Vision/1473R-FPGA/td-p/3232853)

## 14.4 پروژه‌ها و مستندات سخت‌افزاری

1. [NuttX — GC0308 board documentation](https://nuttx.apache.org/docs/latest/platforms/xtensa/esp32s3/boards/lckfb-szpi-esp32s3/index.html)
2. [M5Stack Cam0308 documentation](https://docs.m5stack.com/en/stamp/Stamp-AddOn_Cam0308)
3. [FPGA GC0308 FDMA project](https://icode.best/i/440833415982333)

---

# نتیجه‌گیری

برای تشخیص منشأ خرابی تصویر باید سه مسئله مستقل اثبات شوند:

1. **Acquisition Integrity:** آیا FPGA داده صحیح را از GC0308 دریافت می‌کند؟
2. **Memory Integrity:** آیا همان داده بدون تغییر در HyperRAM ذخیره و بازیابی می‌شود؟
3. **Reconstruction Integrity:** آیا MATLAB داده را با فرمت، ترتیب بایت و ابعاد صحیح بازسازی می‌کند؟

ظاهر تصویر به‌تنهایی برای تشخیص کافی نیست. یک فریم می‌تواند از نظر ابعاد صحیح باشد، اما داده‌های داخلی آن جابه‌جا یا ناقص شده باشند.

**مسیر مرجع پیشنهادی برای ادامه پروژه:**

```text
GC0308 RGB565
      |
      v
FPGA Capture
      |
      v
RGB565 Packing
      |
      v
BRAM
      |
      v
UART
      |
      v
MATLAB
```

پس از تأیید این مسیر، HyperRAM باید به‌عنوان مرحله مستقل اضافه و با CRC و شمارنده‌های Read/Write اعتبارسنجی شود. در نهایت می‌توان YUV422 را با قرارداد بایت مستندشده سنسور آزمایش کرد.

> **اصل طراحی:** هیچ فریمی نباید صرفاً به دلیل داشتن طول مورد انتظار، سالم فرض شود. سلامت شمارش خطوط، تعداد بایت‌ها، وضعیت FIFO و CRC باید جداگانه بررسی شود.


---

# پیوست A — گزارش مکمل اول (متن کامل منبع)

> متن زیر از فایل `gc0308_fpga_investigation_report_tang_nano_4k.md` استخراج شده است. برای حفظ تمام جزئیات و جلوگیری از ادغام مخرب، محتوای گزارش به‌صورت کامل نگهداری شده است.

Technical Investigation Report: GalaxyCore GC0308 FPGA Camera Interface & Image Integrity on Sipeed Tang Nano 4K\
\
\## 1. Executive Summary\
\
The \*\*GalaxyCore GC0308\*\* is a 1/6.5-inch VGA (640 × 480) CMOS image sensor with an active pixel array of 648 × 488, a 10-bit ADC, an on-chip Image Signal Processor (ISP), and support for YCbCr 4:2:2, RGB565, and Raw Bayer output formats at up to 30 fps with a 24 MHz input clock (\`MCLK\`). While public open-source FPGA implementations specifically targeting the GC0308 are relatively sparse compared to OmniVision sensors (such as OV7670 or OV5640), existing sensor documentation, Linux/embedded camera drivers (\`gc0308.c\`, RP2040/ESP32 camera drivers), Gowin HyperRAM IP documentation (\`IPUG944\`), and FPGA video-pipeline engineering cases point to clear failure mechanisms for severe posterization, color distortion, and structured artifacts.\
\
For a \*\*Sipeed Tang Nano 4K\*\* (Gowin \*\*GW1NSR-LV4CQN48P\*\* FPGA with embedded \*\*HyperRAM\*\*) running \*\*VHDL\*\* in \*\*Gowin EDA\*\* and streaming frames over \*\*UART\*\* to \*\*MATLAB\*\*, severe visual corruption—especially \*\*posterization\*\* (stepped intensity/color transitions), \*\*color channel swapping or hue shifts\*\*, \*\*striping/banding\*\*, and \*\*line- or frame-level corruption\*\*—is frequently driven by \*\*pipeline/formatting/memory/clocking mismatches\*\* rather than an inherently defective sensor:\
\
1\. \*\*Pixel format & byte-order / packing mismatch across RGB565, YUV422, and Grayscale\*\* (e.g., byte swapping on 16-bit RGB565 words, treating YCbCr 4:2:2 chroma/luma bytes as RGB565 or extracting luma improperly, or misaligning bit fields during packing into wider memory/UART words).\
2\. \*\*HyperRAM initialization calibration (\`init_calib\`), burst/address alignment, or read/write arbitration & FIFO rate mismatch\*\*—especially critical on the Tang Nano 4K, which uses an integrated \*\*HyperRAM\*\* (rather than external SDRAM or the PSRAM found on some other Gowin packages) and has limited internal Block SRAM (180 Kbits total).\
3\. \*\*Pixel clock (\`PCLK\`), \`HREF\`/\`HSYNC\`, \`VSYNC\` sampling edge/polarity, and clock-domain crossing (CDC)\*\* errors between the sensor pixel domain, HyperRAM controller clock domain, and UART clock domain.\
4\. \*\*Sensor register configuration\*\* (such as format selection, windowing/blanking registers, and ISP/AWB/AEC/gamma settings).\
\
\---\
\
\## 2. GC0308 Sensor Architecture and Output Formats\
\
\### Verified GC0308 Architecture\
Per the GalaxyCore GC0308 Datasheet (\`2010-01-28\`):\
\* \*\*Optical & Pixel Array:\*\* 1/6.5-inch optical format, 3.4 µm × 3.4 µm pixel size, 648 × 488 active pixel array, progressive readout, 4-transistor pixel structure, 2.7–3.3 V supply (typical 2.8 V), \~70 mW active power at 30 fps VGA, \~10 µA standby.\
\* \*\*On-Chip Signal Path:\*\* Pixel array → Column CDS → 10-bit ADC → ISP block (Bayer interpolation/demosaicing, de-noise, color correction, gamma correction, data format conversion, AE, AWB) → Output interface (\`PCLK\`, \`VSYNC\`, \`HSYNC\`/\`HREF\`, parallel data bus).\
\* \*\*Serial Control Bus:\*\* Two-wire serial interface (SCCB/I2C-like); documented serial bus write address is \`0x42\` and read address is \`0x43\` in the GC0308 datasheet.\
\* \*\*Supported Output Formats:\*\* YCbCr 4:2:2, RGB565, and Raw Bayer. (Note: Unlike sensors such as OV2640/OV3660, the GC0308 has \*\*no on-chip JPEG encoder\*\*.)\
\
\### Distinguishing GC0308 from Other GalaxyCore Sensors\
Do \*\*not\*\* treat register maps or I2C addresses of other GalaxyCore sensors as interchangeable with the GC0308 without verification:\
\* \*\*GC0308:\*\* Verified 1/6.5" VGA sensor; datasheet lists two-wire write/read addresses \`0x42\` / \`0x43\` and supports YCbCr 4:2:2, RGB565, and Raw Bayer.\
\* \*\*GC0328 / GC0311 / GC032A / GC0309 / GC0307:\*\* Related GalaxyCore VGA-class sensors appear in embedded drivers and discussions (for example, \`gc0328\` and \`gc0311\` in open-source camera drivers using \`0x21\` as a 7-bit I2C address—note that 7-bit \`0x21\` shifted left by 1 with R/W bit \`0\` equals 8-bit \`0x42\`—and \`GC032A\` / \`GC0309\` / \`GC0307\` in broader camera/driver contexts). Exact bit-fields and register addresses must be verified against the \*\*GC0308\*\* datasheet rather than copied blindly from GC0328/GC0311/GC0309/GC0307 tables.\
\
\### Register Control Mapping (Verified vs. Requires Full Datasheet Verification)\
From the retrieved GC0308 datasheet excerpts and Linux \`gc0308.c\` driver snippets, specific verified registers include:\
\* \*\*Windowing, Blanking, and Frame Timing (Verified in GC0308 Datasheet):\*\*\
&#x20; \* \`P0:0x01\`, \`P0:0x02\`, \`P0:0x0f\` (\`Vb[11:8]\`, \`0x0f[7:4]\`, \`0x0f[3:0]\`) relate to vertical/horizontal blanking (\`VB\` / \`Hb\` dummy lines/pixels).\
&#x20; \* \`P0:0x04\` relates to exposure low byte.\
&#x20; \* \`P0:0x05\`, \`P0:0x06\` relate to row start high/low.\
&#x20; \* \`P0:0x09\`, \`P0:0x0a\` relate to window height (\`win_height\`, where datasheet notes \`Vt = win_height - 8\` and VGA uses \`win_height = 488\` for 480 active lines).\
&#x20; \* \`P0:0x0b\`, \`P0:0x0c\` relate to window width (\`win_width\`, where datasheet notes \`win_width = final_output_width + 8\`, e.g., \`648\` for VGA, and \`row_time = Hb + Sh_delay + win_width + 4\`).\
&#x20; \* \`0x12\` relates to \`Sh_delay\` in the timing equations.\
&#x20; \* \`0x70\` is listed in the datasheet as vertical blanking control affecting frame rate when exposure is less than \`Vb + window Height\`.\
\* \*\*AWB / ISP / Initialization Sequences (Verified in Linux \`gc0308.c\`):\*\*\
&#x20; \* Linux \`gc0308.c\` (\`sunxi-vfe\` and \`amlogic\` drivers) configures multi-register initialization tables, including AWB control (\`0x5b\`, e.g., writing RGB WB gain first and then enabling AWB \`{0x5b, 0x40}\`) and timing/ISP registers (\`0x11\`–\`0x1a\`, \`0x32\`, page-based registers such as \`0x114\`–\`0x13b\` in mainline Linux \`gc0308.c\`).\
\* \*\*Exact Bits for Output Format (YCbCr 4:2:2 vs. RGB565 vs. Raw Bayer), RGB/YUV Selection, Color Matrix, Gamma, and Saturation:\*\*\
&#x20; \* The GC0308 datasheet explicitly states that the sensor supports YCbCr 4:2:2, RGB565, and Raw Bayer and provides register descriptions for frame rate, exposure, window settings, and ISP blocks, \*\*but the exact bit-level register table for format selection, color matrix, gamma, and saturation was not fully reproduced in the search snippets\*\*. Checking the full 32-page GC0308 datasheet register map (Page 0 / Page 1 ISP registers) is required to verify exact bit positions without assuming register addresses from other sensors.\
\
\---\
\
\## 3. Official Timing and Electrical Requirements\
\
\* \*\*Clock and Frame Rate:\*\* Up to 30 fps at 24 MHz input clock (\`MCLK\`) in VGA mode, with pixel output synchronized to \`PCLK\`.\
\* \*\*Sync Signals (\`VSYNC\` and \`HSYNC\`/\`HREF\`):\*\* The GC0308 datasheet timing section describes frame and line timing (\`Ft\`, \`Bt\`, \`VB\`, \`St\`, \`Et\`, \`Vt\`, \`Hb\`, \`Sh_delay\`, \`win_width\`) and illustrates timing with active-low \`VSYNC\` and active-high horizontal sync for YCbCr/RGB565 output.\
\* \*\*Supply & I/O Levels:\*\* 2.7–3.3 V supply range (typical 2.8 V). On the \*\*Sipeed Tang Nano 4K\*\* (\`GW1NSR-LV4CQN48P\`), verify bank I/O voltage standards and pin multiplexing—Sipeed notes that on the Tang Nano 4K, some pins shared/multiplexed with HDMI or headers have external pull-ups or board routing constraints that can affect behavior if not accounted for.\
\* \*\*Serial Bus Timing (GC0308 Datasheet):\*\* Two-wire serial clock \`SBCL\` up to 400 kHz, with \`tlow\` = 1.2 µs (min), \`thigh\` = 1.0 µs (min), \`thd;sta\` = 1.0 µs, \`tsu;sta\` = 1.2 µs, \`tsu;sto\` = 1.2 µs, \`tr\` ≤ 250 ns, \`tf\` ≤ 300 ns.\
\* \*\*Exact \`PCLK\`-to-Data Setup/Hold & \`PCLK\` Frequency Numbers:\*\* Exact nanosecond setup (\`tsu\`) and hold (\`thd\`) timings of parallel pixel data \`D[7:0]\` relative to \`PCLK\` were not captured in the retrieved datasheet text snippets and must be verified directly from the AC timing table in the GC0308 datasheet.\
\
\---\
\
\## 4. Documented FPGA Interface Problems\
\
Below are documented engineering issues across GC0308 implementations, related sensors, and FPGA parallel camera capture pipelines, evaluated for relevance to \*\*GC0308 + Tang Nano 4K (GW1NSR-LV4CQN48P, VHDL, HyperRAM, UART, MATLAB)\*\*.\
\
\### Finding 1 — GC0308 Format & Resolution Mismatch in Embedded/MCU Camera Drivers (\`PicoCamera\` / \`pico-extras\`)\
1\. \*\*Camera sensor and hardware platform:\*\* GC0308 (and multi-sensor drivers including OV2640/OV3660/GC032A) on RP2040 (\`PicoCamera\` / \`pico-extras\`).\
2\. \*\*Original problem description:\*\* Implementing a unified camera capture driver across sensors with differing capabilities (e.g., sensors with vs. without hardware JPEG encoders, and differing supported pixel formats/resolutions).\
3\. \*\*Original image or waveform:\*\* Not provided in the snippet.\
4\. \*\*Exact technical symptoms:\*\* GC0308 has no on-chip JPEG encoder, and format support varies by sensor/driver path (e.g., RGB565 up to VGA, or grayscale mode in specific driver paths).\
5\. \*\*Root cause identified by the original engineer:\*\* Treating all DVP camera sensors as having identical output formats or compression capabilities.\
6\. \*\*Solution or modification applied:\*\* Per-sensor SCCB/I2C detection and explicit format configuration (RGB565 / YCbCr / grayscale) tailored to GC0308 capabilities.\
7\. \*\*Whether the solution was experimentally verified:\*\* Hardware-verified on RP2040 for GC0308 RGB565 capture.\
8\. \*\*Link:\*\* [PicoCamera CHANGELOG]\(https\://github.com/umeiko/PicoCamera/blob/main/CHANGELOG.md) and [raspberrypi/pico-extras Issue #104]\(https\://github.com/raspberrypi/pico-extras/issues/104).\
9\. \*\*Relevance to GC0308 + Tang Nano 4K:\*\* \*\*High.\*\* Confirms GC0308 lacks hardware JPEG compression and requires explicit format/register setup; if MATLAB expects RGB565/YUV422/grayscale while GC0308 outputs another format, images will appear garbled or tinted even when frame geometry is valid.\
\
\### Finding 2 — Word/Halfword Ordering vs. Byte Swapping in Framebuffer Display (\`RX72N GLCDC\` / SDRAM RGB565)\
1\. \*\*Camera sensor and hardware platform:\*\* 16-bit RGB565 framebuffer in external SDRAM (\`480 × 800\` display / framebuffer pipeline).\
2\. \*\*Original problem description:\*\* Text/pixels in an RGB565 framebuffer stored in external RAM appeared slightly pixelated with a faint shadow/extension as if horizontally shifted/stretched.\
3\. \*\*Original image or waveform:\*\* Text rendering artifact described in thread.\
4\. \*\*Exact technical symptoms:\*\* Horizontal pixel/column ordering irregularity when reading/writing 16-bit RGB565 pixels through external memory.\
5\. \*\*Root cause identified by the original engineer:\*\* Engineer/respondent noted that a simple byte swap within a 16-bit RGB565 pixel changes color rather than pixel position, whereas writing/reading two 16-bit pixels (halfwords) in the wrong word order swaps adjacent columns/pixels.\
6\. \*\*Solution or modification applied:\*\* Aligning halfword/word packing and burst ordering between the producer, external memory controller, and consumer.\
7\. \*\*Whether the solution was experimentally verified:\*\* Diagnosed on active hardware thread.\
8\. \*\*Link:\*\* [Reddit r/embedded — GLCDC Text slight pixelated when using framebuffer in sdram]\(https\://www\.reddit.com/r/embedded/comments/1r0wstc/glcdc_text_slight_pixelated_when_using/).\
9\. \*\*Relevance to GC0308 + Tang Nano 4K:\*\* \*\*High.\*\* Your pipeline packs camera bytes into a FIFO, stores them in HyperRAM, reads them out via an output FIFO and UART, and reconstructs them in MATLAB. Any mismatch between byte order (big/little endian within a pixel) and pixel/word order (order of pixels inside a wider burst/UART transfer) will either corrupt colors or shift/corrupt pixels while keeping frame dimensions intact.\
\
\### Finding 3 — VGA Frame Size vs. Buffer Capacity & Incomplete Frame Capture (\`OV7670 + AL422B\` / External RAM)\
1\. \*\*Camera sensor and hardware platform:\*\* VGA (640 × 480) RGB565 camera stream with FIFO and external memory.\
2\. \*\*Original problem description:\*\* Capturing full 640 × 480 VGA frames in RGB565 format resulted in truncated/incomplete frame capture (\`640 × 308\` rather than \`640 × 480\`) when buffer capacity or read-out timing was exceeded.\
3\. \*\*Original image or waveform:\*\* Truncated vertical frame height (\`640 × 308\` instead of \`640 × 480\`).\
4\. \*\*Exact technical symptoms:\*\* Partial frame captured; missing lines/pixels when frame byte count (\`640 × 480 × 2 = 614,400\` bytes for RGB565) exceeded available FIFO or draining rate.\
5\. \*\*Root cause identified by the original engineer:\*\* Insufficient FIFO capacity for a full VGA RGB565 frame (\`384 KB\` AL422B vs. \`600 KB\` / \`614,400\` bytes needed) and consumer/readout rate mismatch during continuous capture.\
6\. \*\*Solution or modification applied:\*\* Synchronizing capture start/stop cleanly with frame sync (\`VSYNC\`), using external RAM sized for full frames, or switching to lower-byte-per-pixel formats when buffer memory is constrained.\
7\. \*\*Whether the solution was experimentally verified:\*\* Verified for QVGA/sub-frames and frame-sync gated capture.\
8\. \*\*Link:\*\* [Electronics Stack Exchange — How can I capture VGA (640x480) frames with RGB565 format from OV7670+FIFO (AL422B)]\(https\://electronics.stackexchange.com/questions/179921/how-can-i-capture-vga-640x480-frames-with-rgb565-format-from-ov7670fifo-al42).\
9\. \*\*Relevance to GC0308 + Tang Nano 4K:\*\* \*\*High.\*\* The Tang Nano 4K's 64 Mbit HyperRAM easily holds VGA frames, \*provided\* write/read pointers, burst lengths, and UART transfer pacing do not overwrite or drop lines.\
\
\### Finding 4 — Clock Domain Crossing & Asynchronous FIFO Requirements in FPGA Video Pipelines\
1\. \*\*Camera sensor and hardware platform:\*\* FPGA parallel/YUV/RGB camera and video pipelines (EEVblog FPGA video / SelectIO discussions).\
2\. \*\*Original problem description:\*\* Interfacing a camera delivering data on its own pixel clock (\`PCLK\`) to downstream FPGA logic running on a different system/memory/output clock.\
3\. \*\*Original image or waveform:\*\* Not provided in the snippet.\
4\. \*\*Exact technical symptoms:\*\* Metastability, dropped/duplicated samples, or timing violations when sampling async/different-clock domains directly.\
5\. \*\*Root cause identified by the original engineer:\*\* Crossing clock domains without a dual-clock (asynchronous) FIFO or proper clock-domain synchronization.\
6\. \*\*Solution or modification applied:\*\* Using a dual-port, dual-clock FIFO between clock domains and referencing single-source clocks carefully for phase vs. frequency differences.\
7\. \*\*Whether the solution was experimentally verified:\*\* Standard FPGA video practice confirmed across forum threads.\
8\. \*\*Link:\*\* [EEVblog — Learning FPGAs for Video Processing]\(https\://www\.eevblog.com/forum/beginners/learning-fpgas-for-video-processing/) and [EEVblog — Syncing a SelectIO serdes module?]\(https\://www\.eevblog.com/forum/microcontrollers/syncing-a-selectio-serdes-module/).\
9\. \*\*Relevance to GC0308 + Tang Nano 4K:\*\* \*\*High.\*\* Your design has multiple clock domains (\`PCLK\` from GC0308, HyperRAM controller/PHY clock, and UART clock). Any improper CDC or unsynchronized FIFO control in VHDL causes intermittent or periodic pixel corruption.\
\
\---\
\
\## 5. Color Distortion and Posterization Root Causes\
\
\### Why RGB565 Quantization Alone Does \*Not\* Explain Severe Posterization\
In standard \*\*RGB565\*\*, Red has 5 bits (32 levels), Green has 6 bits (64 levels), and Blue has 5 bits (32 levels). While 5/6-bit quantization can cause subtle banding on very smooth gradients, \*\*severe posterization\*\* (large, abrupt flat blocks or harsh steps across tones) in an FPGA camera + HyperRAM + UART pipeline is typically caused by \*\*bit truncation/dropping, bit shifting, byte swapping, or YUV-as-RGB misinterpretation\*\*, rather than RGB565's native 5-6-5 resolution alone:\
\* \*\*Accidental Bit Dropping / Bit Shifting:\*\* For example, dropping low bits or shifting color channels by several bit positions (or truncating to fewer bits like RGB332 or dropping MSBs/LSBs during packing into FIFO/HyperRAM/UART) collapses dozens of intensity levels into a handful of steps.\
\* \*\*Byte-Order Swap on RGB565:\*\* In RGB565 (\`R[4:0]\` bits 15:11, \`G[5:0]\` bits 10:5, \`B[4:0]\` bits 4:0), swapping the two bytes of each 16-bit pixel swaps high and low bits across channel boundaries—turning smooth brightness gradients into erratic color shifts and harsh tonal jumps.\
\* \*\*Interpreting YCbCr 4:2:2 as RGB565 (or Vice Versa):\*\* YCbCr 4:2:2 alternates luminance (\`Y\`) and subsampled chrominance (\`Cb\`/\`Cr\`) bytes. Feeding raw YCbCr 4:2:2 bytes into an RGB565 decoder (or reading RGB565 as YCbCr) produces severe color distortion and alternating/blocky chroma artifacts.\
\
\### Specific Visual Artifact Checklist (1–10)\
\| Artifact | Likely Root Cause(s) in FPGA Camera Pipelines | Typical Engineer Fix / Verification | Evidence Tier |\
\| :--- | :--- | :--- | :--- |\
\| \*\*1. Posterization\*\* | Bit truncation/shifting during packing, byte-swapped RGB565, or YUV/RGB format mismatch; ISP gamma/contrast misconfiguration. | Verify raw hex bytes from UART in MATLAB before color conversion; check bit widths and endianness. | General FPGA / Theoretical for GC0308 |\
\| \*\*2. Color banding\*\* | Reduced bit depth per channel (e.g., 5/6-bit RGB565 or further bit reduction) on smooth gradients. | Keep full bit precision until display/MATLAB conversion; apply dithering if needed. | General / Color Depth Theory |\
\| \*\*3. Horizontal stripes\*\* | Line-to-line timing/blanking variation, row/line buffer overwrite or dropped/extra bytes per line, or exposure/banding interaction. | Verify exact byte count per \`HREF\`/\`HSYNC\` active line; check line/HyperRAM row boundaries. | General FPGA / GC0308 Timing |\
\| \*\*4. Vertical stripes\*\* | Column-wise readout/fixed-pattern noise, column/byte phase offset (odd/even byte misalignment across pixels), or burst alignment error. | Check even/odd byte alignment per line (\`VSYNC\`/\`HREF\` reset of byte counter). | General / Camera Sensor Theory |\
\| \*\*5. Color channel corruption\*\* | Swapped R/B/G fields, swapped byte order in RGB565, or swapped U/V (\`Cb\`/\`Cr\`) in YUV422. | Test with a known color target (red, green, blue, white) and inspect byte pairs in MATLAB. | General FPGA / Driver Evidence |\
\| \*\*6. Incorrect color intensity\*\* | Incorrect YUV-to-RGB conversion scale/offset (e.g., full-range vs. limited-range \`Y - 16\`, \`U/V - 128\`) or AWB/gain register state. | Match conversion matrix coefficients and check AWB/gain registers in sensor init. | General / GC0308 Driver (\`0x5b\`) |\
\| \*\*7. Loss of image details\*\* | Over-aggressive smoothing/denoise, downsampling/subsampling, or out-of-focus/blurry/dropped pixels during capture or UART transfer. | Check frame dimensions and inspect an uncompressed/unprocessed test pattern. | General FPGA / Theoretical |\
\| \*\*8. Incorrect grayscale conversion\*\* | Using a single byte from a multi-byte pixel stream without accounting for byte phase (e.g., sampling \`Cb\`/\`Cr\` instead of \`Y\` in YUV422, or taking wrong byte of RGB565). | Isolate \`Y\` bytes explicitly in YCbCr 4:2:2 or compute weighted luma from verified RGB. | General / YUV422 Structure |\
\| \*\*9. Periodic pixel corruption\*\* | HyperRAM refresh/calibration/burst boundary stalls causing FIFO overflow/underflow, or asynchronous FIFO CDC slip. | Monitor FIFO \`full\`/\`empty\` flags and HyperRAM \`init_calib\` / command handshake. | General FPGA / Gowin HyperRAM UG |\
\| \*\*10. Line-dependent color distortion\*\* | Odd/even byte toggle slipping by 1 byte on some lines (e.g., if \`HREF\` ends on an odd byte or counter doesn't reset cleanly per line). | Reset the byte-pair / pixel-packing state machine on every \`HREF\` rising/falling edge and \`VSYNC\`. | General FPGA / Theoretical |\
\
\---\
\
\## 6. RGB565 vs RGB888 vs YUV422 Findings\
\
\* \*\*RGB565:\*\* 16 bits (2 bytes) per pixel (\`5 bits R\`, \`6 bits G\`, \`5 bits B\`). Compact for external RAM (2 bytes/pixel vs. 3 bytes/pixel for RGB888), but requires exact 2-byte pairing and byte-order agreement between camera capture, HyperRAM storage, UART transmission, and MATLAB unpacking.\
\* \*\*RGB888:\*\* 24 bits (3 bytes) per pixel (\`8 bits R\`, \`8 bits G\`, \`8 bits B\`). Higher color precision and memory footprint (1.5× RGB565). Note that the GC0308 datasheet specifies YCbCr 4:2:2, RGB565, and Raw Bayer output formats; if you produce RGB888, it is constructed/expanded in FPGA logic or in MATLAB rather than output natively as parallel 24-bit RGB888.\
\* \*\*YUV422 (YCbCr 4:2:2, YUYV, UYVY):\*\* Averages 2 bytes per pixel across horizontally adjacent pixel pairs (\`Y0\`, \`Cb\`, \`Y1\`, \`Cr\`—or ordered as \`YUYV\` vs. \`UYVY\` depending on byte sequence). Full luma (\`Y\`) resolution is preserved per pixel while chroma (\`U\`/\`V\`) is shared across two horizontal pixels.\
&#x20; \* \*\*Impact of byte-order / chroma-luma ordering errors:\*\* Swapping \`Y\` and \`U\`/\`V\` byte positions or confusing \`YUYV\` vs. \`UYVY\` causes strong false colors (typically magenta/green or cyan/orange shifts) and half-resolution horizontal color smearing.\
\
\---\
\
\## 7. FIFO and External Memory Problems\
\
\### Tang Nano 4K & Gowin HyperRAM Specifics\
\* \*\*Package & Memory Architecture:\*\* The Tang Nano 4K uses the \*\*GW1NSR-LV4CQN48P\*\* FPGA with \*\*64 Mbit HyperRAM\*\* (x8 HyperBus interface) and \*\*180 Kbits of Block SRAM\*\* (plus 2 PLLs and 4,608 LUTs).\
\* \*\*Gowin HyperRAM Interface IP (\`IPUG944\`):\*\* Supports 166 MHz and 200 MHz operating speeds (with 1:2 clock ratio options), configurable burst lengths (such as 16, 32, 64, or 128), and \*\*requires power-on initialization and read calibration (\`init_calib\`)\*\* before reliable read/write transactions.\
\* \*\*Key Failure Modes in FIFO + HyperRAM + UART Pipelines:\*\*\
&#x20; 1\. \*\*Writing/reading before \`init_calib\` completes:\*\* Drops or corrupts initial frames/bursts.\
&#x20; 2\. \*\*Input FIFO overflow:\*\* Occurs when camera \`PCLK\` data arrives faster than HyperRAM bursts can accept it (for instance, during HyperRAM refresh or read-to-write turnaround stalls). Because Block SRAM is 180 Kbits, FIFOs must be sized and backpressured carefully.\
&#x20; 3\. \*\*Output FIFO underflow / UART bottleneck:\*\* UART (e.g., 115200 or even 921600–3 Mbps baud) is vastly slower than camera capture; if the FPGA continues overwriting the HyperRAM frame buffer while UART is still reading an older frame without double-buffering or frame-capture gating, \*\*frame tearing\*\* (top half from frame $N$, bottom half from frame $N+1$) occurs.\
&#x20; 4\. \*\*Burst & address increment mismatch:\*\* If byte vs. word/burst addressing in VHDL increments by the wrong unit (e.g., addressing 16-bit or 32-bit words while counting bytes), addresses wrap or skip locations, producing structured stripes or scrambled blocks.\
\
\---\
\
\## 8. Successful GC0308 FPGA Implementations\
\
Publicly indexed open-source HDL repositories specifically for \*\*GC0308 on Gowin Tang Nano 4K in VHDL\*\* were not directly found in search results, though GC0308 is used in FPGA vision/image-processing projects (such as Anlogic FPGA Verilog projects for scaling and Gaussian filtering) and verified in embedded camera drivers (\`PicoCamera\` on RP2040 and Linux \`gc0308.c\` drivers). Across successful FPGA camera projects generally, engineers succeed by:\
1\. Validating the \*\*capture & transport path\*\* with a synthetic test pattern (color bars or ramp) before trusting live camera pixels.\
2\. Locking down \*\*exact pixel format and byte/word order\*\* end-to-end.\
3\. Using \*\*dual-clock FIFOs\*\* across clock domains and gating frame writes cleanly around \`VSYNC\` and external memory calibration (\`init_calib\`).\
\
\---\
\
\## 9. Comparison of Reported Solutions\
\
\| Approach / Mechanism | Strengths | Failure Risks if Misconfigured | Applicability to Tang Nano 4K + GC0308 |\
\| :--- | :--- | :--- | :--- |\
\| \*\*RGB565 (2 bytes/px)\*\* | Compact 16-bit pixel format; straightforward in MATLAB. | Byte swap corrupts colors; halfword/burst order swap shifts pixels. | High — verify exact byte & pixel order. |\
\| \*\*YCbCr 4:2:2 (2 bytes/px avg)\*\* | Preserves full \`Y\` luma; standard sensor ISP format. | \`YUYV\` vs. \`UYVY\` or \`Y\`/chroma swap causes severe color shifts. | High — confirm exact byte sequence. |\
\| \*\*Grayscale / \`Y\`-only extraction\*\* | Low bandwidth/data volume; fast UART transfer & simple check. | Sampling wrong byte phase reads chroma instead of \`Y\`. | High — ideal early diagnostic mode. |\
\| \*\*HyperRAM Frame Buffer (\`IPUG944\`)\*\* | Large capacity (64 Mbit) on GW1NSR-LV4CQN48P. | Using before \`init_calib\`, burst/address mismatch, or UART overwrite. | Core hardware memory in your design. |\
\| \*\*Dual-Clock FIFOs + \`VSYNC\` Gating\*\* | Safely bridges \`PCLK\`, HyperRAM, and UART domains; prevents frame tearing. | Incorrect FIFO depth or ignored \`full\`/\`empty\` flags drops pixels. | Essential for reliable capture & UART dump. |\
\
\---\
\
\## 10. Root-Cause Ranking for My Project\
\
Ranked by likelihood for \*\*severe posterization, color distortion, and structured artifacts\*\* in a \*\*GC0308 → VHDL Capture/Packing → FIFO → HyperRAM → Output FIFO → UART → MATLAB\*\* pipeline (all ranked as \*\*hypotheses to test\*\*, not proven causes):\
\
1\. \*\*Pixel Format Interpretation, Byte Ordering, and Packing Mismatch (Rank 1 — High Likelihood):\*\* Mismatched byte order within 16-bit RGB565/YUV422 pixels, swapped \`Y\`/\`U\`/\`V\` or \`YUYV\`/\`UYVY\` order, wrong bit slicing/shifting during VHDL packing, or MATLAB decoding the stream with a different format/endianness than the GC0308 register setting.\
2\. \*\*HyperRAM Read/Write, Addressing, Calibration, or Frame-Buffer Contention (Rank 2 — High Likelihood):\*\* Writing/reading before \`init_calib\`, address/burst increment errors, or concurrent camera writes and slow UART reads tearing/corrupting the frame buffer.\
3\. \*\*FIFO Rate Mismatch & Clock-Domain Crossing (Rank 3 — Medium-High Likelihood):\*\* Input FIFO overflow during HyperRAM stalls or CDC issues across \`PCLK\`, HyperRAM, and UART clocks.\
4\. \*\*Sensor Register Configuration & Sampling Timing (\`PCLK\`/\`HREF\`/\`VSYNC\`) (Rank 4 — Medium Likelihood):\*\* Incorrect output format/windowing/ISP register values, wrong \`PCLK\` edge or \`VSYNC\`/\`HREF\` polarity, or Tang Nano 4K pin/IO constraints.\
\
\---\
\
\## 11. Recommended Debugging and Validation Strategy\
\
Follow this isolated, step-by-step verification sequence in VHDL, Gowin EDA, and MATLAB:\
\
1\. \*\*Bypass the Camera with a Known Synthetic Pattern (Isolate HyperRAM + UART + MATLAB):\*\*\
&#x20;  \* Feed a deterministic ramp or color-bar test pattern (e.g., incrementing byte counter \`0x00..0xFF\` or known RGB565 bars) directly into the input FIFO / HyperRAM write path and read it back over UART into MATLAB.\
&#x20;  \* \*Verification:\* If the reconstructed MATLAB image shows steps, stripes, or shifting before the camera is even connected, the bug is in packing, HyperRAM addressing/calibration, UART framing, or MATLAB parsing—not the GC0308.\
2\. \*\*Verify \`VSYNC\`, \`HREF\`/\`HSYNC\`, and \`PCLK\` Counts:\*\*\
&#x20;  \* Count \`PCLK\` rising/falling edges per active \`HREF\` line and count active \`HREF\` lines per \`VSYNC\` frame in VHDL (using logic analyzer / Gowin Signal Tap or LED/counter debug).\
&#x20;  \* \*Verification:\* Confirm consistent active bytes per line and 480 lines per frame (for VGA) without erratic per-line counts.\
3\. \*\*Test One Output Format End-to-End with Explicit Raw Hex Inspection:\*\*\
&#x20;  \* Configure GC0308 via SCCB/I2C (\`0x42\` write address) and print/save raw received bytes in MATLAB before any color conversion.\
&#x20;  \* \*Verification:\* For RGB565, verify 2 bytes per pixel against known red/green/blue targets; for YCbCr 4:2:2, verify luma vs. chroma behavior; for grayscale/luma check, verify smooth brightness gradients without harsh bit-shift steps.\
4\. \*\*Gate Frame Capture During UART Readout:\*\*\
&#x20;  \* Capture a single frame into HyperRAM after \`init_calib\` is asserted, pause new camera overwrites to that buffer while UART drains the frame to MATLAB, and check FIFO \`overflow\`/\`underflow\` sticky flags.\
&#x20;  \* \*Verification:\* Frame tearing and periodic corruption disappear when buffer contention and FIFO overflows are eliminated.\
\
\---\
\
\## 12. References and Original Discussion Links\
\
\* \*\*GC0308 Datasheet & Timing/Registers:\*\*\
&#x20; \* [GalaxyCore GC0308 Datasheet (Kamami PDF)]\(https\://download.kamami.pl/p1197045-GC0308.pdf)\
&#x20; \* [GalaxyCore GC0308 Datasheet (Scribd)]\(https\://www\.scribd.com/doc/219250257/GalaxyCore-GC0308-Datasheet-v1)\
&#x20; \* [Linux Kernel Driver — \`gc0308.c\` (CodeBrowser)]\(https\://codebrowser.dev/linux/linux/drivers/media/i2c/gc0308.c.html)\
&#x20; \* [Allwinner \`gc0308.c\` Driver (GitHub)]\(https\://github.com/allwinner-zh/linux-3.4-sunxi/blob/master/drivers/media/video/sunxi-vfe/device/gc0308.c)\
&#x20; \* [Amlogic \`gc0308.c\` Driver (GitHub)]\(https\://github.com/endlessm/linux-meson/blob/master/drivers/amlogic/camera/gc0308.c)\
\* \*\*GC0308 / Multi-Sensor Camera Drivers:\*\*\
&#x20; \* [PicoCamera CHANGELOG (GitHub)]\(https\://github.com/umeiko/PicoCamera/blob/main/CHANGELOG.md)\
&#x20; \* [raspberrypi/pico-extras Issue #104 (GitHub)]\(https\://github.com/raspberrypi/pico-extras/issues/104)\
&#x20; \* [PicoCamera Repository (GitHub)]\(https\://github.com/umeiko/PicoCamera)\
\* \*\*Tang Nano 4K & Gowin HyperRAM Documentation:\*\*\
&#x20; \* [Tang Nano 4K — Sipeed Wiki]\(https\://wiki.sipeed.com/hardware/en/tang/Tang-Nano-4K/Nano-4K.html)\
&#x20; \* [SiPeed Tang Nano 4K — Gowin Semiconductor]\(https\://gowinsemi.com/en/support/devkits_detail/39)\
&#x20; \* [Gowin HyperRAM Memory Interface IP User Guide (\`IPUG944\`)]\(https\://www\.gowinsemi.com/upload/database_doc/1162/document/5ff46062305dc.pdf)\
&#x20; \* [Using GoWin GW1NSR-LV4C PSRAM and HyperRAM? (Reddit r/FPGA)]\(https\://www\.reddit.com/r/FPGA/comments/vdzowh/using_gowin_gw1nsrlv4c_psram_and_hyperram/)\
\* \*\*FPGA Camera Capture, Memory, & Format Discussions:\*\*\
&#x20; \* [How can I capture VGA (640x480) frames with RGB565 format from OV7670+FIFO (AL422B) (Electronics Stack Exchange)]\(https\://electronics.stackexchange.com/questions/179921/how-can-i-capture-vga-640x480-frames-with-rgb565-format-from-ov7670fifo-al42)\
&#x20; \* [GLCDC Text slight pixelated when using framebuffer in sdram (Reddit r/embedded)]\(https\://www\.reddit.com/r/embedded/comments/1r0wstc/glcdc_text_slight_pixelated_when_using/)\
&#x20; \* [Learning FPGAs for Video Processing (EEVblog)]\(https\://www\.eevblog.com/forum/beginners/learning-fpgas-for-video-processing/)\
&#x20; \* [Syncing a SelectIO serdes module? (EEVblog)]\(https\://www\.eevblog.com/forum/microcontrollers/syncing-a-selectio-serdes-module/)\
&#x20; \* [Application of Serializers with Camera Chips — YUV422 & FPGA Conversion (Analog Devices)]\(https\://www\.analog.com/en/resources/technical-articles/application-of-serializers-with-camera-chips.html)



که مال جمنای هست&#x20;



و



\# FPGA-Based GC0308 Interface: Documented Failure Modes and Root-Cause Analysis\
\
\*\*Research scope note:\*\* This report prioritizes primary engineering evidence: forum threads with resolved outcomes, driver source commits, and register documentation. Findings are explicitly partitioned by evidence strength. Where the requested detail (a verified GC0308 + Tang Nano 4K + HyperRAM implementation) does not exist in accessible sources, that is stated rather than fabricated.\
\
\---\
\
\## 1. Executive Summary\
\
The most consequential finding for the user's project is that \*\*the dominant documented cause of severe color distortion and structured artifacts on the GC0308 is not sensor malfunction, but byte-level and format-level mismatches between what the sensor serializes and what the receiving logic assumes\*\*. Three specific failure modes recur across independent platforms:\
\
1\. \*\*YUV422 byte-order mismatch\*\* (YUYV vs. UYVY) produces a characteristic “green/purple” cast with a recognizable image silhouette—not random noise. The encoder/display side reads chroma as luma and vice versa. This is confirmed on ESP32-S3 with GC0308 and is a standard CSI debugging checkpoint on Allwinner platforms.\
\
2\. \*\*RGB565 big-endian serialization without byte-swap\*\* produces recognizable images with saturated false color, or severe banding if a byte-slip occurs. A GC0308 driver commit explicitly documents that on an 8-bit DVP bus, the \*\*high byte is clocked out first\*\*, yielding RGB565X (big-endian). An ESP32-CAM fix describes the exact signature: “odd byte lost in RGB565 swaps the bytes of every following pixel: recognisable image, saturated false colour.”\
\
3\. \*\*RGB444 output mode produces contour-like water-ripple artifacts\*\* that disappear entirely when switching to RGB565. This is an experimentally resolved case on a direct FPGA-to-display path, with the original engineer confirming the fix. The most plausible mechanism is that RGB444 packs 12 bits into a byte stream that the downstream logic misinterprets, generating structured quantization bands rather than uniform noise.\
\
A fourth finding directly relevant to the user's HyperRAM architecture: \*\*HyperRAM bandwidth limitation can cause visible tearing or banding when used as a real-time frame buffer\*\*, whereas on-chip RAM does not exhibit the artifact. This was documented on a Renesas platform, not with GC0308 specifically, but the architectural principle applies.\
\
No verified public implementation of GC0308 + Gowin Tang Nano 4K + HyperRAM was found. The Tang Nano 4K's documented DVP camera support is for OV2640, not GC0308. This does not mean the user's approach is infeasible, but it means the integration must be validated incrementally rather than by reference to a known-good design.\
\
\---\
\
\## 2. GC0308 Sensor Architecture and Output Formats (Confirmed GC0308-Specific)\
\
The GC0308 is a 640×480 (VGA) CMOS sensor with an active array of 648×488 pixels (the extra columns/rows serve ISP margins). It integrates an on-chip ISP performing Bayer interpolation, denoise, color correction, gamma correction, and format conversion. The digital output is via an 8-bit DVP (Digital Video Port) with PCLK, HREF (HSYNC), and VSYNC.\
\
\### 2.1 Output Format Register (0x24)\
\
The primary format selector is \*\*register 0x24, bits[3:0]\*\*. Verified mappings from Linux kernel and NuttX driver sources:\
\
\| Register 0x24 bits[3:0] | Output format | Media bus code / note | Source |\
\|---|---|---|---|\
\| \`0x02\` | YUYV (YCbCr422) | \`MEDIA_BUS_FMT_YUYV8_2X8\` | Linux GC0308 driver patch |\
\| \`0x03\` | YVYU (YCbCr422 variant) | \`MEDIA_BUS_FMT_YVYU8_2X8\` | Same |\
\| \`0x06\` | \*\*RGB565\*\* | \`MEDIA_BUS_FMT_RGB565_2X8_BE\` — \*\*big-endian\*\* | Same; NuttX commit |\
\| \`0x07\` | RGB555 | \`RGB555_2X8_PADHI_BE\` | Linux driver patch |\
\| \`0x09\` | RGB444 | \`RGB444_2X8_PADHI_BE\` | Linux driver patch |\
\| \`0xa2\` (full byte) | YCbYCr (YUV422) | Default in some SDKs | ARCS SDK default registers |\
\
\*\*Critical distinction:\*\* \`0x06\` selects RGB565, and the \`\_BE\` suffix in the media bus code is not incidental. A NuttX commit explicitly states: “On an 8-bit DVP bus the high byte is clocked out first, so the pixel data arrives in memory in big-endian order (RGB565X).” This means the byte sequence for one pixel is \`[R4:R0 G5:G3]\` then \`[G2:G0 B4:B0]\`, and a little-endian consumer that reads the two bytes as a 16-bit word will see the green bits split incorrectly and the color channels reversed in a structured way—not random noise.\
\
\### 2.2 Timing and Synchronization Polarity (Register 0x26)\
\
Register 0x26 bits[2:0] configure VSYNC/HREF/PCLK polarity. A documented example: when 0x26 = 0x01, VSYNC is high-active, HREF is low-active, and data is launched on the \*\*falling edge\*\* of PCLK. The receiving controller must then be configured with opposite sampling polarity (sample on rising edge if the sensor launches on falling, or vice versa, depending on the controller's convention). This is a common source of one-pixel horizontal shifts or duplicated/missing pixels at line boundaries.\
\
A Linux device-tree binding for GC0308 shows \`pclk-sample = <1>\` (sample on rising edge), indicating that rising-edge sampling is the default expectation for at least one integration. The user's FPGA must match whatever 0x26 is programmed to, and the PCLK edge used in the capture process must be verified against the actual launch edge, not assumed.\
\
\---\
\
\## 3. Documented FPGA / Embedded Interface Problems\
\
\### 3.1 RGB444 Mode → Contour-Like Water-Ripple Artifacts (Resolved, FPGA Path)\
\
\*\*Platform:\*\* FPGA directly driving a display from GC0308, no JPEG/H.264 compression. \*\*Problem:\*\* Image showed noise-like artifacts resembling contour lines or water ripples. \*\*Root cause identified by original engineer:\*\* Sensor was configured for RGB444 output. \*\*Solution:\*\* Changing the sensor output configuration to RGB565 eliminated the artifact; the engineer reported the image quality “became good” and the “contour-line water-ripple problem was solved.” \*\*Verification:\*\* Experimentally confirmed by the original poster.\
\
\*\*Relevance to the user:\*\* This is the single most directly applicable resolved case because it involves an FPGA receiving GC0308 data and displaying it. If the user's design has been experimented with “different output representations,” an RGB444 or RGB555 mode may have been engaged inadvertently, or the downstream packing logic may be treating a non-RGB565 stream as RGB565. The artifact described—structured contour bands, not uniform noise—matches the user's “posterization” and “structured image artifacts” description more closely than random FIFO corruption would.\
\
\### 3.2 YUV422 Byte-Order Mismatch → Green/Purple Cast with Recognizable Silhouette\
\
\*\*Platform:\*\* ESP32-S3 + GC0308 (CoreS3-Lite), with a JPEG encoder in the pipeline. \*\*Problem:\*\* Image outline correct, frame rate correct, resolution correct, but overall green or purple cast; white walls not white; faces cyan. White balance adjustment and resolution changes did not help. \*\*Root cause:\*\* The capture side declared one YUV422 byte order and the encoder side declared the other. The two conventions are:\
\
\| Convention | Four-byte sequence | Alias |\
\|---|---|---|\
\| Y-Cb-Y-Cr | Y₀, Cb, Y₁, Cr | YUY2 / YUYV |\
\| Cb-Y-Cr-Y | Cb, Y₀, Cr, Y₁ | UYVY |\
\
Both are “YUV422,” both have the same byte count, so \*\*no length error is raised\*\*. The decoder reads luma as chroma and chroma as luma, swapping the brightness and color channels. \*\*Solution:\*\* Ensure the format declaration on the capture side and the encoder/consumer side match exactly. The engineer provided a methodology: capture a frame of a white sheet and inspect the first 16 raw bytes to determine which byte positions carry luma vs. chroma.\
\
\*\*Relevance to the user:\*\* If the user's MATLAB reconstruction treats the received byte stream as YUV422 but the GC0308 is programmed for UYVY while MATLAB assumes YUYV (or vice versa), the exact symptom will be a tinted image with preserved geometry. This should be the first hypothesis tested if the image is recognizable but uniformly color-shifted.\
\
\### 3.3 RGB565 Byte-Slip → Recognizable Image with Saturated False Color (Resolved at Driver Level)\
\
\*\*Platform:\*\* ESP32-S3 + GC0308, VGA/RGB565, PSRAM DMA path. \*\*Problem:\*\* Frames exhibited a “byte-slip signature”: an odd byte was lost, causing \*\*every following pixel's bytes to be swapped\*\*. The result was a recognizable image with saturated false color. The driver did not warn because the DMA descriptor chain reported lengths that summed to less than the frame capacity, but the application still received the buffer as if complete. \*\*Root cause:\*\* DMA transfer stopped early, leaving trailing descriptors at zero length; the incomplete frame was silently delivered. \*\*Solution:\*\* Sum the descriptor lengths and drop the frame (\`en = 1\`) when they do not add up to the chain capacity, converting silent corruption into a visible dropped frame.\
\
\*\*Relevance to the user:\*\* The user's architecture includes a FIFO and HyperRAM. If the capture FIFO overflows or the HyperRAM write burst is interrupted—whether due to bandwidth contention, a clock-domain-crossing stall, or an address-generation bug—the resulting byte stream will be \*\*misaligned by one byte\*\*. In RGB565, this produces exactly the “swapped bytes of every following pixel” signature: colors become wildly saturated but the image remains geometrically recognizable. This is a \*\*critical\*\* hypothesis for the user's “severe posterization and color distortion” if the artifacts begin at a specific horizontal position or after a certain number of pixels.\
\
\### 3.4 PCLK Sampling Edge Mismatch → One-Pixel Shift / Line-Dependent Corruption\
\
\*\*Platform:\*\* Allwinner CSI (general principle, GC0308 named). \*\*Problem:\*\* Large areas of green and purple with normal outline. \*\*Root cause identified:\*\* (a) YUYV order mismatch, or (b) PCLK sampling edge wrong relative to the sensor's launch edge, causing data to be sampled at a transition. \*\*Solution:\*\* First verify YUYV order against the sensor spec; if correct, adjust the PCLK sampling edge.\
\
\*\*Relevance to the user:\*\* The GC0308 launches data on either the rising or falling edge depending on register 0x26. If the FPGA capture process samples on the same edge as the launch, setup/hold violations will cause intermittent bit errors that appear as line-dependent or position-dependent corruption. This is distinct from a byte-order issue: byte-order errors affect all pixels uniformly, whereas sampling-edge errors often vary with data pattern and trace delay.\
\
\### 3.5 Input Format Mismatch in Downstream ISP → Stripes (Non-FPGA, but Architecturally Instructive)\
\
\*\*Platform:\*\* NUC980 CSI. \*\*Problem:\*\* When a Y-only sensor was used but the controller was configured for RGB565 input, the image had stripes. \*\*Documented explanation:\*\* “If the input image format is RGB565, [the controller] will first convert to YUV422, which destroys the data.” The controller's internal path expected YUV422 and performed a conversion that was inappropriate for an RGB565 stream. The solution was to configure both INFMT and OUTFMT consistently as YUV422.\
\
\*\*Relevance to the user:\*\* This reinforces that \*\*format declarations at every stage of the pipeline must be consistent\*\*. If the user's FPGA capture controller inserts a format-conversion stage—or if the packing logic for HyperRAM storage assumes a different format than the sensor's register 0x24 setting—the data will be corrupted before it ever reaches MATLAB.\
\
\### 3.6 HyperRAM Bandwidth Limitation → Tearing / Banding in Real-Time Frame Buffering\
\
\*\*Platform:\*\* Renesas platform (not GC0308-specific). \*\*Problem:\*\* After moving camera input buffers to external HyperRAM, severe tearing appeared. \*\*Root cause:\*\* HyperRAM bandwidth was lower than required for the real-time display path. \*\*Recommended solution:\*\* Place real-time display buffers in on-chip RAM; use HyperRAM only for non-real-time data, or move only a portion of the display buffer to HyperRAM if on-chip capacity is insufficient.\
\
\*\*Relevance to the user:\*\* The Tang Nano 4K's HyperRAM is 64 Mb, 8-bit wide, with the Gowin datasheet listing a maximum operating frequency of 80 MHz for the hard memory controller. At 8 bits × 80 MHz, the theoretical peak is 80 MB/s (640 Mb/s). A 640×480 RGB565 frame at 30 fps requires approximately 18.4 MB/s, which is within peak bandwidth, but \*\*real-time capture and readback contend for the same bus\*\*, and HyperRAM has significant latency for random-access and bank-crossing patterns. If the capture FIFO drains to HyperRAM while the UART readback is simultaneously fetching a previous frame, the effective write bandwidth can collapse, causing FIFO overflow and the byte-slip corruption described in 3.3. This is a structural risk in the user's architecture, not a hypothetical one.\
\
\### 3.7 Unresolved Community Cases (No Confirmed Root Cause)\
\
Several forum threads describe color errors with RGB565 that were never resolved by the original posters:\
\
\- OpenEdv thread (STM32F407 + GC0308, RGB565 320×240): “color incorrect, RGB big/little endian confirmed should be correct”; multiple users reported the same problem, no resolution posted. Another user in the same thread reported “many stripes” in the image and could not find a byte-swap bit in the GC0308 datasheet.\
\- OpenEdv thread (STM32F407): “image color parsing is always wrong, tried all output modes, none correct,” with an attached RGB565 image showing data corruption. No root cause was confirmed.\
\- 51hei thread: “image outline roughly correct but color wrong, overall dark,” no resolution posted.\
\
These unresolved cases are important because they demonstrate that \*\*“endianness confirmed correct” by the developer is not equivalent to “byte stream verified by inspection of raw data.”\*\* In the absence of a raw-byte capture, developers frequently misidentify the source of the mismatch.\
\
\---\
\
\## 4. Color Distortion and Posterization: Root-Cause Ranking for This Project\
\
The table below ranks hypotheses by \*\*specificity to the GC0308 + FPGA + HyperRAM architecture\*\* and by the \*\*availability of corroborating primary evidence\*\*.\
\
\| Rank | Hypothesis | Expected visual signature | Corroborating evidence | How to falsify |\
\|---|---|---|---|---|\
\| \*\*1\*\* | \*\*RGB565 big-endian output not byte-swapped for MATLAB\*\* | Recognizable image, saturated/reversed colors; uniform across frame | NuttX commit explicitly documents RGB565X big-endian output on 8-bit DVP | Capture one frame to a file; inspect bytes for a known uniform-color object; check whether swapping every two bytes yields plausible RGB565 |\
\| \*\*2\*\* | \*\*YUV422 byte-order mismatch (YUYV vs. UYVY)\*\* | Green/purple or cyan/magenta cast; geometry intact; luma/chroma swapped | ESP32-S3 resolved case with byte-level methodology; Allwinner CSI debugging checkpoint | Same raw-byte inspection: determine whether Y or Cb occupies byte 0 of each four-byte group |\
\| \*\*3\*\* | \*\*FIFO overflow / HyperRAM write stall → byte-slip\*\* | Corruption begins at a specific column or after a burst of pixels; subsequent pixels have swapped bytes → saturated false color | ESP32-CAM byte-slip signature is identical; HyperRAM bandwidth warning documented | Reduce PCLK frequency or insert wait states to eliminate overflow; if artifact disappears, bandwidth/FIFO is causal |\
\| \*\*4\*\* | \*\*PCLK sampling edge wrong\*\* | Intermittent bit errors, often line-dependent or data-pattern-dependent; not uniform across all pixels | Allwinner guidance: adjust PCLK sampling edge after YUYV check | Use a logic analyzer or ILA to compare PCLK edge vs. data transitions; try opposite edge |\
\| \*\*5\*\* | \*\*RGB444 or RGB555 mode inadvertently selected\*\* | Contour-like water-ripple bands, “posterization” appearance | Resolved FPGA case: RGB444 caused contour artifacts; RGB565 fixed it | Read register 0x24 back via I2C/SCCB after initialization; confirm bits[3:0] = 0x06 for RGB565 |\
\| \*\*6\*\* | \*\*Sensor register 0x24 misconfigured for a different format than MATLAB assumes\*\* | Could produce any of the above depending on actual vs. assumed format | Register 0x24 mapping verified | Same: read back 0x24 and compare to the format assumed in MATLAB reconstruction |\
\
\*\*Why hypothesis 5 is ranked above a pure “sensor problem”:\*\* The user reports having experimented with “RGB565, YUV422, Grayscale” and modified packing/buffering. If a previous build left the sensor in RGB444 or RGB555 mode and only the MATLAB side was changed, the resulting mismatch would produce structured bands that could easily be misattributed to “posterization” from bit-depth truncation. The resolved FPGA case confirms this is a real failure mode on a direct FPGA path.\
\
\---\
\
\## 5. Successful GC0308 Implementations and What They Did Differently\
\
\### 5.1 NuttX GC0308 Driver (RGB565X Reporting)\
\
The NuttX commit changes the reported pixel format from \`V4L2_PIX_FMT_RGB565\` to \`V4L2_PIX_FMT_RGB565X\` when register 0x24 is set to \`0x06\`. The commit message states the reason explicitly: the high byte is clocked out first on the 8-bit DVP bus, so memory layout is big-endian. The driver then allows userspace to detect this and byte-swap if needed for a little-endian display path. The key differentiator is \*\*explicit format reporting based on the sensor's actual serialization order\*\*, not an assumption that “RGB565” means little-endian 16-bit words.\
\
\### 5.2 Linux Mainline GC0308 Driver (Format Enumeration)\
\
The Linux driver defines distinct media bus codes for YUYV (\`0x02\`), YVYU (\`0x03\`), RGB565 big-endian (\`0x06\`), RGB555 (\`0x07\`), and RGB444 (\`0x09\`). By enumerating these as separate formats rather than a single “RGB565” label, the driver prevents the exact ambiguity that causes byte-order mismatches. It also defines \`GC0308_OUT_FORMAT\` at register \`0x024\` and configures format dynamically in \`start_capture()\` based on the requested pixel format.\
\
\### 5.3 ESP32-S3 Byte-Order Fix (Software Reconstruction)\
\
The CoreS3-Lite case resolved a green/purple cast by aligning the capture-side and encoder-side YUV422 byte-order declarations. The engineer emphasized that both sides must declare the same four-byte sequence and provided a raw-frame-header inspection method. This is a successful reconstruction because the fix was verified against the observable artifact, not just against a register value.\
\
\### 5.4 “Milink” FPGA Tutorial Series (SDRAM Frame Buffer, Not HyperRAM)\
\
Chinese FPGA training materials reference a GC0308 camera + SDRAM frame buffer + HDMI output example, and a Sobel edge-detection example. However, \*\*no source code or register initialization sequence was accessible\*\* in the search results, and these examples use SDRAM, not HyperRAM. They are noted as existence proofs of GC0308 + FPGA frame-buffer pipelines, but they cannot be used to validate the user's HyperRAM architecture or byte-order handling.\
\
\### 5.5 What Is Notably Absent\
\
No public, verified implementation of \*\*GC0308 + Gowin Tang Nano 4K + HyperRAM + UART + MATLAB\*\* was found. The Tang Nano 4K's documented camera support is for OV2640. This absence does not invalidate the user's approach, but it means the HyperRAM timing, Gowin-specific FIFO IP behavior, and UART bandwidth constraints must be validated from first principles rather than by copying a known-good design.\
\
\---\
\
\## 6. FIFO and External Memory Architecture: Specific Risks in This Design\
\
The user's pipeline is:\

---

# پیوست B — گزارش مکمل دوم (متن کامل منبع)

> متن زیر شامل راهنمای مبتنی بر شواهد و تحلیل خطاهای گزارش‌شده است. محتوای گزارش به‌صورت کامل نگهداری شده است.

GC0308 FPGA Interface — Evidence-Based Failure Analysis & Debugging Guide\
\
\*\*Scope:\*\* GalaxyCore GC0308 DVP sensor interfaced to FPGA (emphasis: Gowin / Tang Nano class devices, VHDL, optional HyperRAM frame buffer, UART-to-host path).  \
\*\*Method:\*\* Primary sources only (datasheet, mainline Linux driver, verified register tables). No fabricated forum threads. Correlation vs causation is stated explicitly.  \
\*\*Audience:\*\* VHDL engineer who already gets \*some\* image but with severe color/structure corruption.\
\
\---\
\
\## 1. Executive Summary\
\
\| Rank | Root cause | Typical visual symptom | Evidence strength |\
\|------|------------|------------------------|-------------------|\
\| 1 | Register \`0x24\` format mismatch (YUV vs RGB565) | Severe false color, “oil paint”, wrong hues | \*\*Proven\*\* (datasheet + Linux driver) |\
\| 2 | Bit 7 of \`0x24\` wrong (ISP high-8 / low-8) | Posterization / banding, low dynamic range | \*\*Proven\*\* (datasheet bit field) |\
\| 3 | Byte-phase slip (no reset on HREF falling edge) | Horizontal color stripes, shifted columns | \*\*Strong engineering causation\*\* (DVP 2-byte pixel) |\
\| 4 | \`0x26\` polarity / PCLK gating wrong | Missing lines, tearing, partial frames | \*\*Proven\*\* (datasheet) |\
\| 5 | \`win_width ≠ 648\` | Wrong line length, edge artifacts | \*\*Proven\*\* (datasheet formula) |\
\| 6 | HyperRAM / FIFO starvation | Horizontal tears, lost lines, frame drops | \*\*Platform-specific, high likelihood on Tang Nano 4K\*\* |\
\| 7 | Downstream UART framing / host byte reorder | Structured corruption only after dump | \*\*Path-dependent\*\* |\
\| 8 | Pure RGB565 quantization | Mild banding on gradients only | \*\*Weak\*\* for \*severe\* posterization |\
\
\*\*Hard rule:\*\* Do \*\*not\*\* attribute severe posterization to RGB565 quantization. RGB565 alone produces mild banding on smooth gradients; it does \*\*not\*\* produce wild false color or structured stripes. Those symptoms almost always originate in format selection, byte phase, or memory/transport, not in the sensor’s 5-6-5 packing.\
\
\---\
\
\## 2. Sensor Architecture (Verified)\
\
\### 2.1 Physical / electrical\
\
\| Parameter | Value | Source |\
\|-----------|-------|--------|\
\| Optical format | 1/6.5″ | Datasheet |\
\| Active array | 648 × 488 | Datasheet |\
\| Output resolution (VGA) | 640 × 480 | Driver + datasheet |\
\| ADC | 10-bit | Datasheet |\
\| Max rate | \~30 fps @ 24 MHz MCLK, VGA | Datasheet / Linux \`GC0308_PIXEL_RATE 24000000\` |\
\| I²C write / read address | \`0x42\` / \`0x43\` | Datasheet |\
\| Chip ID | \`0x9B\` (some printings \`0x9A\`) | Datasheet / driver |\
\
\### 2.2 Output path\
\
Sensor → 10-bit ADC → on-chip ISP → format packer → DVP pins (\`DATA[7:0]\`, \`PCLK\`, \`HREF\`/\`HSYNC\`, \`VSYNC\`).\
\
Critical register \*\*\`P0:0x24\` (Output_format)\*\* (datasheet):\
\
\| Bits | Meaning |\
\|------|---------|\
\| \`[4:0]\` | Output data mode |\
\| \`[5]\` | Average chroma |\
\| \`[6]\` | Output delay |\
\| \`[7]\` | ISP high-8 (\`1\`) or low-8 (\`0\`) of the 10-bit path |\
\
Documented modes (subset):\
\
\| \`[4:0]\` | Format |\
\|---------|--------|\
\| \`0x00\` | Cb Y Cr Y |\
\| \`0x01\` | Cr Y Cb Y |\
\| \`0x02\` | Y Cb Y Cr |\
\| \`0x03\` | Y Cr Y Cb |\
\| \`0x06\` | \*\*RGB565\*\* |\
\| \`0x07\` | RGB x555 |\
\| … | other / bypass / single-channel |\
\
Default in datasheet and Linux init: \*\*\`0xA2\`\*\*  \
→ bit7 = 1 (high-8), bits[4:0] = \`0x02\` → \*\*Y Cb Y Cr\*\* (YUYV-order family).\
\
Linux mainline mapping (\`drivers/media/i2c/gc0308.c\`):\
\
\`\`\`text\
UYVY  → 0x00\
VYUY  → 0x01\
YUYV  → 0x02\
YVYU  → 0x03\
RGB565_BE → 0x06



Driver updates only the low 5 bits while preserving bit 7 when possible; default table still writes `0xa2`.

### 2.3 Timing math (datasheet, non-negotiable)

Text
```ini
win_width  = final_output_width + 8     → VGA: 640 + 8 = 648
win_height = 488                        → Vt = win_height - 8 = 480
row_time   = Hb + Sh_delay + win_width + 4
```

Linux driver hard-codes `GC0308_WIN_WIDTH = 648`, `GC0308_WIN_HEIGHT = 488`.

### 2.4 Sync register `P0:0x26` (sync_mode)

Datasheet fields (summary):

| Bit         | Function                       |
| ----------- | ------------------------------ |
| `[0]`       | VSYNC polarity                 |
| `[1]`       | HSYNC polarity                 |
| `[2]`       | PCLK polarity                  |
| `[3]`       | PCLK gated in horizontal blank |
| `[4]`/`[5]` | allow PCLK around VSYNC/HSYNC  |
| `[6]`/`[7]` | half-cycle delays              |

Linux uses **`0x03`**. Datasheet default is often shown as `0x3F`. Polarity mismatch between sensor and FPGA sampler is a primary cause of dropped or shifted lines.

## 3. Documented / Mechanistically Proven Problem Classes

### 3.1 Color distortion / false color (highest frequency)

**Mechanism**



FPGA assumes RGB565 byte stream:

Text
```ini
byte0 = RRRRRGGG
byte1 = GGGBBBBB
```

while sensor is still in YUV422 (e.g. `Y0 Cb Y1 Cr` or `Cb Y Cr Y`). Interpreting chroma as color primaries produces saturated wrong hues.



**Evidence**

- Datasheet explicitly separates YUV modes (`0x00`–`0x03`) from RGB565 (`0x06`).
- Linux driver never treats those mode values as interchangeable.

**Diagnostic**

1. Read back `0x24`.
2. Force `0xA6` (high-8 + RGB565) or `0xA2` (high-8 + YUYV) and compare.
3. If colors snap into a coherent palette after the change, the fault was format, not the ISP.

### 3.2 Posterization / banding (severe)

**Two distinct causes**

| Cause                                      | Visual                                           | How to confirm                                             |
| ------------------------------------------ | ------------------------------------------------ | ---------------------------------------------------------- |
| Bit 7 of `0x24` = 0 (low-8 of 10-bit path) | Stair-step luminance, crushed shadows/highlights | Read `0x24`; set bit 7; banding collapses                  |
| True RGB565 quantization                   | Mild bands only on smooth gradients              | Present even with correct registers and solid capture path |

**Do not** diagnose “RGB565 is only 16-bit” until bit 7 and format bits are verified. Severe posterization with structured artifacts is almost never pure quantization.

### 3.3 Horizontal / vertical stripes

**Byte-phase slip (most common structural fault)**



RGB565 and YUV422 are both 2 bytes/pixel. If the capture FSM does not reset its byte counter on HREF falling edge (or equivalent end-of-line), the phase inverts permanently:

Text
```yaml
correct:  [R G] [G B] [R G] ...
slipped:  [G B] [R G] [G B] ...
```

Result: vertical color stripes or every other column wrong.



**VSYNC / HREF polarity or edge selection**



Wrong edge on PCLK or inverted HREF produces:

- missing first/last pixels of every line
- whole-frame shear
- intermittent line drops

**FIFO / HyperRAM underrun**



On Gowin devices with on-chip HyperRAM/PSRAM, short-burst efficiency is low. If the write path cannot sustain line rate, lines are lost or repeated → horizontal tears. This is a **system** problem, not a sensor register problem.

### 3.4 Incorrect brightness / contrast

Usually AEC/AGC or gamma registers, **or** the low-8 vs high-8 slice (bit 7 of `0x24`). Secondary: wrong digital gain / saturation (`0xB0`–`0xB3` family).

### 3.5 Missing / corrupted pixels

- `win_width` ≠ 648 → line length mismatch
- HREF gated PCLK ignored → idle clocks counted as data
- CDC without proper gray-code or FIFO → metastable counts

### 3.6 RGB565 vs RGB888 reconstruction errors

GC0308 does not output RGB888 on DVP in the normal modes listed above. If the host expects 24-bit and the FPGA pads zeros or repeats bytes, the image looks posterized. Confirm the actual wire format before writing conversion logic.

### 3.7 YUV422 order (YUYV / UYVY / …)

Order is fully determined by `0x24[4:0]`. Swapping U/V or Y/C in the unpacker produces green/magenta faces and is often mis-labeled “AWB failure”.

### 3.8 Byte ordering (endian)

Linux registers RGB565 as **big-endian** on the bus (`MEDIA_BUS_FMT_RGB565_2X8_BE`). If the FPGA or host swaps bytes, red/blue exchange or green shift appears.

### 3.9 FIFO overflow / underflow

Classic dual-clock FIFO between PCLK domain and system/HyperRAM domain. Overflow → dropped pixels; underflow on the read side → tears on the display/UART path. Measure almost-full / almost-empty flags; do not guess.

## 4. Root-Cause Ranking for Tang Nano 4K + HyperRAM + VHDL + UART Path

Assumed platform constraints:

- GW1NSR-class fabric, limited BRAM
- On-package HyperRAM / PSRAM with modest effective bandwidth under short bursts
- Frame dump over UART to MATLAB/PC

| Priority | Check                                                              | Why on this platform                                |
| -------- | ------------------------------------------------------------------ | --------------------------------------------------- |
| P0       | `0x24` read-back = expected (`0xA6` for RGB565 or `0xA2` for YUYV) | Format errors dominate all “color is wrong” reports |
| P0       | Bit 7 of `0x24` = 1                                                | Direct cause of severe posterization                |
| P0       | Bytes per line = 1280 (640×2) while HREF high                      | Phase / width errors                                |
| P1       | Byte counter hard-reset on HREF ↓                                  | Prevents permanent phase slip                       |
| P1       | `0x26` polarity matches FPGA sampling edge                         | Sync integrity                                      |
| P1       | BRAM line buffer only (no HyperRAM) still clean                    | Isolates memory subsystem                           |
| P2       | HyperRAM burst length / efficiency                                 | Known weak point of short random bursts             |
| P2       | UART framing / host endian                                         | Corruption only after host receive                  |
| P3       | Supply / IO voltage (DOVDD vs FPGA bank)                           | Level mismatch → intermittent bit errors            |

## 5. Recommended Debug Sequence (Do Not Skip Steps)

### Step 0 — Lock the sensor

1. Soft reset (`0xFE` page / soft-reset sequence as in datasheet).
2. Write a **minimal** known-good table derived from Linux defaults.
3. **Read back** every critical register (`0x00` chip ID, `0x24`, `0x26`, `0x0B/0x0C` width, `0x09/0x0A` height).
4. If read-back ≠ written value, stop. You do not have a working I²C path.

### Step 1 — Prove the wire format

- Configure **RGB565** (`0x24 = 0xA6` if high-8 required).
- Or configure **YUYV** (`0xA2`) and unpack as YUV in the FPGA — never both assumptions at once.

### Step 2 — Count, do not look

In the PCLK domain:

Vhdl
```lua
-- conceptual
if href = '1' then
  byte_count <= byte_count + 1;
else
  -- on falling edge of href: latch byte_count, then clear
end if;
```

Expect **1280** bytes/line for 640-pixel RGB565 or YUV422.\
&#x20;Any other steady count is a width, phase, or HREF problem.

### Step 3 — BRAM-only capture

Capture one line (or a few lines) into BRAM. Bypass HyperRAM and UART.\
&#x20;If the line is clean in BRAM and dirty after HyperRAM/UART, the sensor is innocent.

### Step 4 — Test pattern

If the sensor exposes a test-pattern / color-bar mode via debug registers, enable it.\
&#x20;A perfect bar in BRAM and a broken bar after the memory path localizes the fault to the fabric, not the ISP.

### Step 5 — Re-introduce HyperRAM

Use long bursts. Monitor FIFO flags. Never stream PCLK-rate writes into a low-efficiency memory controller without elastic buffering.

### Step 6 — UART / host

Only after the frame is correct in FPGA memory. Host-side byte swaps and lost UART bytes produce structured corruption that is easily mistaken for sensor failure.

## 6. Minimal VHDL Capture Skeleton (Conceptual)

Vhdl
```arduino
-- PCLK domain
process(pclk)
begin
  if rising_edge(pclk) then
    if href = '1' then
      if byte_phase = '0' then
        pix_hi <= data8;
        byte_phase <= '1';
        pix_valid <= '0';
      else
        pix_lo <= data8;
        byte_phase <= '0';
        pix_valid <= '1';  -- one pixel ready
      end if;
    else
      byte_phase <= '0';    -- CRITICAL: reset phase every line
      pix_valid  <= '0';
    end if;
  end if;
end process;
```

Notes:

- Choose rising vs falling edge of `pclk` to match `0x26[2]` and measured setup/hold.
- Cross `pix_valid` + 16-bit pixel into the system clock domain only through a dual-clock FIFO.
- Reset line address on the appropriate VSYNC edge (match `0x26[0]`).

## 7. Register Quick Reference (Working Baseline)

Derived from mainline Linux `gc0308.c` + datasheet constraints:

| Register    | Typical value                    | Role                     |
| ----------- | -------------------------------- | ------------------------ |
| `0x00`      | `0x9B`                           | Chip ID (read)           |
| `0x0B/0x0C` | `0x02` / `0x88`                  | win_width = 648          |
| `0x09/0x0A` | `0x01` / `0xE8`                  | win_height = 488         |
| `0x24`      | `0xA2` (YUYV) or `0xA6` (RGB565) | Format + high-8          |
| `0x25`      | `0x0F`                           | Output enables           |
| `0x26`      | `0x03` (Linux)                   | Sync polarities / gating |
| `0xFE`      | page select                      | 0 = page0                |

Always **read back**. Blind write lists from random blogs are a common source of silent misconfiguration.

## 8. What Is *Not* Supported by Evidence

- Claims that GC0308 “always” needs a specific Chinese blog init table without read-back verification.
- Treating GC0308 and GC0328/GC0309 as register-compatible without checking each ID and format map.
- Attributing severe false color solely to RGB565 bit depth.
- Assuming HyperRAM is “fast enough” without measuring sustained write bandwidth under the actual burst pattern.

## 9. Practical Order of Work (Against Perfectionism / Task Paralysis)

You will not fix everything in one sitting. Execute **only** this closed loop:

1. I²C read-back of `0x00`, `0x24`, `0x26`, width/height.
2. Force one format (`0xA6` or `0xA2`).
3. Measure bytes/line = 1280.
4. Capture one clean line in BRAM.
5. Only then touch HyperRAM or UART.

If step 4 fails, steps 5+ are wasted motion. If step 4 passes, the sensor and your sampling edge are adequate; the remaining bugs are in memory or host path.

## 10. References & Source Links

### Primary datasheet sources

- [GC0308 Datasheet (PDF) – whycan mirror](https://whycan.com/files/members/3/GC0308_Datasheet.pdf)
- [GC0308 Datasheet (PDF) – M5Stack / CoreS3 resource](https://m5stack.oss-cn-shenzhen.aliyuncs.com/resource/docs/datasheet/core/K128%20CoreS3/GC0308.PDF)
- [GC0308 Datasheet HTML extract – Timing / win_width = 648](https://www.alldatasheet.com/html-pdf/1221285/ETC1/GC0308/1046/9/GC0308.html)
- [GC0308 Datasheet HTML extract – Register 0x24 Output_format](https://www.alldatasheet.com/html-pdf/1221285/ETC1/GC0308/1631/14/GC0308.html)

### Linux / driver sources (verified register values)

- [Mainline Linux gc0308.c (codebrowser)](https://codebrowser.dev/linux/linux/drivers/media/i2c/gc0308.c.html)
- [Allwinner sunxi gc0308.c (older but useful init tables)](https://github.com/allwinner-zh/linux-3.4-sunxi/blob/master/drivers/media/video/sunxi-vfe/device/gc0308.c)

### Related platform / memory notes

- [Portable HyperRAM controller (VHDL) – useful for understanding burst efficiency issues](https://github.com/MJoergen/HyperRAM)
- [HyperRAM controller documentation site](https://mjoergen.github.io/HyperRAM/)

**Bottom line for a hard grader:**\
&#x20;Your first image is not a success metric. A **correct** image is defined by: (1) register read-back matches intent, (2) 1280 bytes per HREF, (3) stable content in on-chip BRAM before any external memory or UART is involved. Everything else is secondary.





Driver updates only the low 5 bits while preserving bit 7 when possible; default table still writes `0xa2`.

### 2.3 Timing math (datasheet, non-negotiable)

Text
```ini
win_width  = final_output_width + 8     → VGA: 640 + 8 = 648
win_height = 488                        → Vt = win_height - 8 = 480
row_time   = Hb + Sh_delay + win_width + 4
```

Linux driver hard-codes `GC0308_WIN_WIDTH = 648`, `GC0308_WIN_HEIGHT = 488`.

### 2.4 Sync register `P0:0x26` (sync_mode)

Datasheet fields (summary):

| Bit         | Function                       |
| ----------- | ------------------------------ |
| `[0]`       | VSYNC polarity                 |
| `[1]`       | HSYNC polarity                 |
| `[2]`       | PCLK polarity                  |
| `[3]`       | PCLK gated in horizontal blank |
| `[4]`/`[5]` | allow PCLK around VSYNC/HSYNC  |
| `[6]`/`[7]` | half-cycle delays              |

Linux uses **`0x03`**. Datasheet default is often shown as `0x3F`. Polarity mismatch between sensor and FPGA sampler is a primary cause of dropped or shifted lines.

## 3. Documented / Mechanistically Proven Problem Classes

### 3.1 Color distortion / false color (highest frequency)

**Mechanism**



FPGA assumes RGB565 byte stream:

Text
```ini
byte0 = RRRRRGGG
byte1 = GGGBBBBB
```

while sensor is still in YUV422 (e.g. `Y0 Cb Y1 Cr` or `Cb Y Cr Y`). Interpreting chroma as color primaries produces saturated wrong hues.



**Evidence**

- Datasheet explicitly separates YUV modes (`0x00`–`0x03`) from RGB565 (`0x06`).
- Linux driver never treats those mode values as interchangeable.

**Diagnostic**

1. Read back `0x24`.
2. Force `0xA6` (high-8 + RGB565) or `0xA2` (high-8 + YUYV) and compare.
3. If colors snap into a coherent palette after the change, the fault was format, not the ISP.

### 3.2 Posterization / banding (severe)

**Two distinct causes**

| Cause                                      | Visual                                           | How to confirm                                             |
| ------------------------------------------ | ------------------------------------------------ | ---------------------------------------------------------- |
| Bit 7 of `0x24` = 0 (low-8 of 10-bit path) | Stair-step luminance, crushed shadows/highlights | Read `0x24`; set bit 7; banding collapses                  |
| True RGB565 quantization                   | Mild bands only on smooth gradients              | Present even with correct registers and solid capture path |

**Do not** diagnose “RGB565 is only 16-bit” until bit 7 and format bits are verified. Severe posterization with structured artifacts is almost never pure quantization.

### 3.3 Horizontal / vertical stripes

**Byte-phase slip (most common structural fault)**



RGB565 and YUV422 are both 2 bytes/pixel. If the capture FSM does not reset its byte counter on HREF falling edge (or equivalent end-of-line), the phase inverts permanently:

Text
```yaml
correct:  [R G] [G B] [R G] ...
slipped:  [G B] [R G] [G B] ...
```

Result: vertical color stripes or every other column wrong.



**VSYNC / HREF polarity or edge selection**



Wrong edge on PCLK or inverted HREF produces:

- missing first/last pixels of every line
- whole-frame shear
- intermittent line drops

**FIFO / HyperRAM underrun**



On Gowin devices with on-chip HyperRAM/PSRAM, short-burst efficiency is low. If the write path cannot sustain line rate, lines are lost or repeated → horizontal tears. This is a **system** problem, not a sensor register problem.

### 3.4 Incorrect brightness / contrast















گراگ

Driver updates only the low 5 bits while preserving bit 7 when possible; default table still writes 0xa2.
2.3 Timing math (datasheet, non-negotiable)
Text

win_width  = final_output_width + 8     → VGA: 640 + 8 = 648
win_height = 488                        → Vt = win_height - 8 = 480
row_time   = Hb + Sh_delay + win_width + 4

Linux driver hard-codes GC0308_WIN_WIDTH = 648, GC0308_WIN_HEIGHT = 488.
2.4 Sync register P0:0x26 (sync_mode)

Datasheet fields (summary):
Bit	Function
[0]	VSYNC polarity
[1]	HSYNC polarity
[2]	PCLK polarity
[3]	PCLK gated in horizontal blank
[4]/[5]	allow PCLK around VSYNC/HSYNC
[6]/[7]	half-cycle delays

Linux uses 0x03. Datasheet default is often shown as 0x3F. Polarity mismatch between sensor and FPGA sampler is a primary cause of dropped or shifted lines.
3. Documented / Mechanistically Proven Problem Classes
3.1 Color distortion / false color (highest frequency)

Mechanism

FPGA assumes RGB565 byte stream:
Text

byte0 = RRRRRGGG
byte1 = GGGBBBBB

while sensor is still in YUV422 (e.g. Y0 Cb Y1 Cr or Cb Y Cr Y). Interpreting chroma as color primaries produces saturated wrong hues.

Evidence

    Datasheet explicitly separates YUV modes (0x00–0x03) from RGB565 (0x06).
    Linux driver never treats those mode values as interchangeable.

Diagnostic

    Read back 0x24.
    Force 0xA6 (high-8 + RGB565) or 0xA2 (high-8 + YUYV) and compare.
    If colors snap into a coherent palette after the change, the fault was format, not the ISP.

3.2 Posterization / banding (severe)

Two distinct causes
Cause	Visual	How to confirm
Bit 7 of 0x24 = 0 (low-8 of 10-bit path)	Stair-step luminance, crushed shadows/highlights	Read 0x24; set bit 7; banding collapses
True RGB565 quantization	Mild bands only on smooth gradients	Present even with correct registers and solid capture path

Do not diagnose “RGB565 is only 16-bit” until bit 7 and format bits are verified. Severe posterization with structured artifacts is almost never pure quantization.
3.3 Horizontal / vertical stripes

Byte-phase slip (most common structural fault)

RGB565 and YUV422 are both 2 bytes/pixel. If the capture FSM does not reset its byte counter on HREF falling edge (or equivalent end-of-line), the phase inverts permanently:
Text

correct:  [R G] [G B] [R G] ...
slipped:  [G B] [R G] [G B] ...

Result: vertical color stripes or every other column wrong.

VSYNC / HREF polarity or edge selection

Wrong edge on PCLK or inverted HREF produces:

    missing first/last pixels of every line
    whole-frame shear
    intermittent line drops

FIFO / HyperRAM underrun

On Gowin devices with on-chip HyperRAM/PSRAM, short-burst efficiency is low. If the write path cannot sustain line rate, lines are lost or repeated → horizontal tears. This is a system problem, not a sensor register problem.
3.4 Incorrect brightness / contrast

Usually AEC/AGC or gamma registers, or the low-8 vs high-8 slice (bit 7 of 0x24). Secondary: wrong digital gain / saturation (0xB0–0xB3 family).
3.5 Missing / corrupted pixels

    win_width ≠ 648 → line length mismatch
    HREF gated PCLK ignored → idle clocks counted as data
    CDC without proper gray-code or FIFO → metastable counts

3.6 RGB565 vs RGB888 reconstruction errors

GC0308 does not output RGB888 on DVP in the normal modes listed above. If the host expects 24-bit and the FPGA pads zeros or repeats bytes, the image looks posterized. Confirm the actual wire format before writing conversion logic.
3.7 YUV422 order (YUYV / UYVY / …)

Order is fully determined by 0x24[4:0]. Swapping U/V or Y/C in the unpacker produces green/magenta faces and is often mis-labeled “AWB failure”.
3.8 Byte ordering (endian)

Linux registers RGB565 as big-endian on the bus (MEDIA_BUS_FMT_RGB565_2X8_BE). If the FPGA or host swaps bytes, red/blue exchange or green shift appears.
3.9 FIFO overflow / underflow

Classic dual-clock FIFO between PCLK domain and system/HyperRAM domain. Overflow → dropped pixels; underflow on the read side → tears on the display/UART path. Measure almost-full / almost-empty flags; do not guess.
4. Root-Cause Ranking for Tang Nano 4K + HyperRAM + VHDL + UART Path

Assumed platform constraints:

    GW1NSR-class fabric, limited BRAM
    On-package HyperRAM / PSRAM with modest effective bandwidth under short bursts
    Frame dump over UART to MATLAB/PC

Priority	Check	Why on this platform
P0	0x24 read-back = expected (0xA6 for RGB565 or 0xA2 for YUYV)	Format errors dominate all “color is wrong” reports
P0	Bit 7 of 0x24 = 1	Direct cause of severe posterization
P0	Bytes per line = 1280 (640×2) while HREF high	Phase / width errors
P1	Byte counter hard-reset on HREF ↓	Prevents permanent phase slip
P1	0x26 polarity matches FPGA sampling edge	Sync integrity
P1	BRAM line buffer only (no HyperRAM) still clean	Isolates memory subsystem
P2	HyperRAM burst length / efficiency	Known weak point of short random bursts
P2	UART framing / host endian	Corruption only after host receive
P3	Supply / IO voltage (DOVDD vs FPGA bank)	Level mismatch → intermittent bit errors
5. Recommended Debug Sequence (Do Not Skip Steps)
Step 0 — Lock the sensor

    Soft reset (0xFE page / soft-reset sequence as in datasheet).
    Write a minimal known-good table derived from Linux defaults.
    Read back every critical register (0x00 chip ID, 0x24, 0x26, 0x0B/0x0C width, 0x09/0x0A height).
    If read-back ≠ written value, stop. You do not have a working I²C path.

Step 1 — Prove the wire format

    Configure RGB565 (0x24 = 0xA6 if high-8 required).
    Or configure YUYV (0xA2) and unpack as YUV in the FPGA — never both assumptions at once.

Step 2 — Count, do not look

In the PCLK domain:
Vhdl

-- conceptual
if href = '1' then
  byte_count <= byte_count + 1;
else
  -- on falling edge of href: latch byte_count, then clear
end if;

Expect 1280 bytes/line for 640-pixel RGB565 or YUV422.
Any other steady count is a width, phase, or HREF problem.
Step 3 — BRAM-only capture

Capture one line (or a few lines) into BRAM. Bypass HyperRAM and UART.
If the line is clean in BRAM and dirty after HyperRAM/UART, the sensor is innocent.
Step 4 — Test pattern

If the sensor exposes a test-pattern / color-bar mode via debug registers, enable it.
A perfect bar in BRAM and a broken bar after the memory path localizes the fault to the fabric, not the ISP.
Step 5 — Re-introduce HyperRAM

Use long bursts. Monitor FIFO flags. Never stream PCLK-rate writes into a low-efficiency memory controller without elastic buffering.
Step 6 — UART / host

Only after the frame is correct in FPGA memory. Host-side byte swaps and lost UART bytes produce structured corruption that is easily mistaken for sensor failure.
6. Minimal VHDL Capture Skeleton (Conceptual)
Vhdl

-- PCLK domain
process(pclk)
begin
  if rising_edge(pclk) then
    if href = '1' then
      if byte_phase = '0' then
        pix_hi <= data8;
        byte_phase <= '1';
        pix_valid <= '0';
      else
        pix_lo <= data8;
        byte_phase <= '0';
        pix_valid <= '1';  -- one pixel ready
      end if;
    else
      byte_phase <= '0';    -- CRITICAL: reset phase every line
      pix_valid  <= '0';
    end if;
  end if;
end process;

Notes:

    Choose rising vs falling edge of pclk to match 0x26[2] and measured setup/hold.
    Cross pix_valid + 16-bit pixel into the system clock domain only through a dual-clock FIFO.
    Reset line address on the appropriate VSYNC edge (match 0x26[0]).

7. Register Quick Reference (Working Baseline)

Derived from mainline Linux gc0308.c + datasheet constraints:
Register	Typical value	Role
0x00	0x9B	Chip ID (read)
0x0B/0x0C	0x02 / 0x88	win_width = 648
0x09/0x0A	0x01 / 0xE8	win_height = 488
0x24	0xA2 (YUYV) or 0xA6 (RGB565)	Format + high-8
0x25	0x0F	Output enables
0x26	0x03 (Linux)	Sync polarities / gating
0xFE	page select	0 = page0

Always read back. Blind write lists from random blogs are a common source of silent misconfiguration.
8. What Is Not Supported by Evidence

    Claims that GC0308 “always” needs a specific Chinese blog init table without read-back verification.
    Treating GC0308 and GC0328/GC0309 as register-compatible without checking each ID and format map.
    Attributing severe false color solely to RGB565 bit depth.
    Assuming HyperRAM is “fast enough” without measuring sustained write bandwidth under the actual burst pattern.

9. Practical Order of Work (Against Perfectionism / Task Paralysis)

You will not fix everything in one sitting. Execute only this closed loop:

    I²C read-back of 0x00, 0x24, 0x26, width/height.
    Force one format (0xA6 or 0xA2).
    Measure bytes/line = 1280.
    Capture one clean line in BRAM.
    Only then touch HyperRAM or UART.

If step 4 fails, steps 5+ are wasted motion. If step 4 passes, the sensor and your sampling edge are adequate; the remaining bugs are in memory or host path.
10. References & Source Links
Primary datasheet sources

    [GC0308 Datasheet (PDF) – whycan mirror](https://whycan.com/files/members/3/GC0308_Datasheet.pdf)
    [GC0308 Datasheet (PDF) – M5Stack / CoreS3 resource](https://m5stack.oss-cn-shenzhen.aliyuncs.com/resource/docs/datasheet/core/K128%20CoreS3/GC0308.PDF)
    [GC0308 Datasheet HTML extract – Timing / win_width = 648](https://www.alldatasheet.com/html-pdf/1221285/ETC1/GC0308/1046/9/GC0308.html)
    [GC0308 Datasheet HTML extract – Register 0x24 Output_format](https://www.alldatasheet.com/html-pdf/1221285/ETC1/GC0308/1631/14/GC0308.html)

Linux / driver sources (verified register values)

    [Mainline Linux gc0308.c (codebrowser)](https://codebrowser.dev/linux/linux/drivers/media/i2c/gc0308.c.html)
    [Allwinner sunxi gc0308.c (older but useful init tables)](https://github.com/allwinner-zh/linux-3.4-sunxi/blob/master/drivers/media/video/sunxi-vfe/device/gc0308.c)

Related platform / memory notes

    [Portable HyperRAM controller (VHDL) – useful for understanding burst efficiency issues](https://github.com/MJoergen/HyperRAM)
    [HyperRAM controller documentation site](https://mjoergen.github.io/HyperRAM/)

Bottom line for a hard grader:
Your first image is not a success metric. A correct image is defined by: (1) register read-back matches intent, (2) 1280 bytes per HREF, (3) stable content in on-chip BRAM before any external memory or UART is involved. Everything else is secondary.

Usually AEC/AGC or gamma registers, **or** the low-8 vs high-8 slice (bit 7 of `0x24`). Secondary: wrong digital gain / saturation (`0xB0`–`0xB3` family).

### 3.5 Missing / corrupted pixels

- `win_width` ≠ 648 → line length mismatch
- HREF gated PCLK ignored → idle clocks counted as data
- CDC without proper gray-code or FIFO → metastable counts

### 3.6 RGB565 vs RGB888 reconstruction errors

GC0308 does not output RGB888 on DVP in the normal modes listed above. If the host expects 24-bit and the FPGA pads zeros or repeats bytes, the image looks posterized. Confirm the actual wire format before writing conversion logic.

### 3.7 YUV422 order (YUYV / UYVY / …)

Order is fully determined by `0x24[4:0]`. Swapping U/V or Y/C in the unpacker produces green/magenta faces and is often mis-labeled “AWB failure”.

### 3.8 Byte ordering (endian)

Linux registers RGB565 as **big-endian** on the bus (`MEDIA_BUS_FMT_RGB565_2X8_BE`). If the FPGA or host swaps bytes, red/blue exchange or green shift appears.

### 3.9 FIFO overflow / underflow

Classic dual-clock FIFO between PCLK domain and system/HyperRAM domain. Overflow → dropped pixels; underflow on the read side → tears on the display/UART path. Measure almost-full / almost-empty flags; do not guess.

## 4. Root-Cause Ranking for Tang Nano 4K + HyperRAM + VHDL + UART Path

Assumed platform constraints:

- GW1NSR-class fabric, limited BRAM
- On-package HyperRAM / PSRAM with modest effective bandwidth under short bursts
- Frame dump over UART to MATLAB/PC

| Priority | Check                                                              | Why on this platform                                |
| -------- | ------------------------------------------------------------------ | --------------------------------------------------- |
| P0       | `0x24` read-back = expected (`0xA6` for RGB565 or `0xA2` for YUYV) | Format errors dominate all “color is wrong” reports |
| P0       | Bit 7 of `0x24` = 1                                                | Direct cause of severe posterization                |
| P0       | Bytes per line = 1280 (640×2) while HREF high                      | Phase / width errors                                |
| P1       | Byte counter hard-reset on HREF ↓                                  | Prevents permanent phase slip                       |
| P1       | `0x26` polarity matches FPGA sampling edge                         | Sync integrity                                      |
| P1       | BRAM line buffer only (no HyperRAM) still clean                    | Isolates memory subsystem                           |
| P2       | HyperRAM burst length / efficiency                                 | Known weak point of short random bursts             |
| P2       | UART framing / host endian                                         | Corruption only after host receive                  |
| P3       | Supply / IO voltage (DOVDD vs FPGA bank)                           | Level mismatch → intermittent bit errors            |

## 5. Recommended Debug Sequence (Do Not Skip Steps)

### Step 0 — Lock the sensor

1. Soft reset (`0xFE` page / soft-reset sequence as in datasheet).
2. Write a **minimal** known-good table derived from Linux defaults.
3. **Read back** every critical register (`0x00` chip ID, `0x24`, `0x26`, `0x0B/0x0C` width, `0x09/0x0A` height).
4. If read-back ≠ written value, stop. You do not have a working I²C path.

### Step 1 — Prove the wire format

- Configure **RGB565** (`0x24 = 0xA6` if high-8 required).
- Or configure **YUYV** (`0xA2`) and unpack as YUV in the FPGA — never both assumptions at once.

### Step 2 — Count, do not look

In the PCLK domain:

Vhdl
```lua
-- conceptual
if href = '1' then
  byte_count <= byte_count + 1;
else
  -- on falling edge of href: latch byte_count, then clear
end if;
```

Expect **1280** bytes/line for 640-pixel RGB565 or YUV422.\
&#x20;Any other steady count is a width, phase, or HREF problem.

### Step 3 — BRAM-only capture

Capture one line (or a few lines) into BRAM. Bypass HyperRAM and UART.\
&#x20;If the line is clean in BRAM and dirty after HyperRAM/UART, the sensor is innocent.

### Step 4 — Test pattern

If the sensor exposes a test-pattern / color-bar mode via debug registers, enable it.\
&#x20;A perfect bar in BRAM and a broken bar after the memory path localizes the fault to the fabric, not the ISP.

### Step 5 — Re-introduce HyperRAM

Use long bursts. Monitor FIFO flags. Never stream PCLK-rate writes into a low-efficiency memory controller without elastic buffering.

### Step 6 — UART / host

Only after the frame is correct in FPGA memory. Host-side byte swaps and lost UART bytes produce structured corruption that is easily mistaken for sensor failure.

## 6. Minimal VHDL Capture Skeleton (Conceptual)

Vhdl
```arduino
-- PCLK domain
process(pclk)
begin
  if rising_edge(pclk) then
    if href = '1' then
      if byte_phase = '0' then
        pix_hi <= data8;
        byte_phase <= '1';
        pix_valid <= '0';
      else
        pix_lo <= data8;
        byte_phase <= '0';
        pix_valid <= '1';  -- one pixel ready
      end if;
    else
      byte_phase <= '0';    -- CRITICAL: reset phase every line
      pix_valid  <= '0';
    end if;
  end if;
end process;
```

Notes:

- Choose rising vs falling edge of `pclk` to match `0x26[2]` and measured setup/hold.
- Cross `pix_valid` + 16-bit pixel into the system clock domain only through a dual-clock FIFO.
- Reset line address on the appropriate VSYNC edge (match `0x26[0]`).

## 7. Register Quick Reference (Working Baseline)

Derived from mainline Linux `gc0308.c` + datasheet constraints:

| Register    | Typical value                    | Role                     |
| ----------- | -------------------------------- | ------------------------ |
| `0x00`      | `0x9B`                           | Chip ID (read)           |
| `0x0B/0x0C` | `0x02` / `0x88`                  | win_width = 648          |
| `0x09/0x0A` | `0x01` / `0xE8`                  | win_height = 488         |
| `0x24`      | `0xA2` (YUYV) or `0xA6` (RGB565) | Format + high-8          |
| `0x25`      | `0x0F`                           | Output enables           |
| `0x26`      | `0x03` (Linux)                   | Sync polarities / gating |
| `0xFE`      | page select                      | 0 = page0                |

Always **read back**. Blind write lists from random blogs are a common source of silent misconfiguration.

## 8. What Is *Not* Supported by Evidence

- Claims that GC0308 “always” needs a specific Chinese blog init table without read-back verification.
- Treating GC0308 and GC0328/GC0309 as register-compatible without checking each ID and format map.
- Attributing severe false color solely to RGB565 bit depth.
- Assuming HyperRAM is “fast enough” without measuring sustained write bandwidth under the actual burst pattern.

## 9. Practical Order of Work (Against Perfectionism / Task Paralysis)

You will not fix everything in one sitting. Execute **only** this closed loop:

1. I²C read-back of `0x00`, `0x24`, `0x26`, width/height.
2. Force one format (`0xA6` or `0xA2`).
3. Measure bytes/line = 1280.
4. Capture one clean line in BRAM.
5. Only then touch HyperRAM or UART.

If step 4 fails, steps 5+ are wasted motion. If step 4 passes, the sensor and your sampling edge are adequate; the remaining bugs are in memory or host path.

## 10. References & Source Links

### Primary datasheet sources

- [GC0308 Datasheet (PDF) – whycan mirror](https://whycan.com/files/members/3/GC0308_Datasheet.pdf)
- [GC0308 Datasheet (PDF) – M5Stack / CoreS3 resource](https://m5stack.oss-cn-shenzhen.aliyuncs.com/resource/docs/datasheet/core/K128%20CoreS3/GC0308.PDF)
- [GC0308 Datasheet HTML extract – Timing / win_width = 648](https://www.alldatasheet.com/html-pdf/1221285/ETC1/GC0308/1046/9/GC0308.html)
- [GC0308 Datasheet HTML extract – Register 0x24 Output_format](https://www.alldatasheet.com/html-pdf/1221285/ETC1/GC0308/1631/14/GC0308.html)

### Linux / driver sources (verified register values)

- [Mainline Linux gc0308.c (codebrowser)](https://codebrowser.dev/linux/linux/drivers/media/i2c/gc0308.c.html)
- [Allwinner sunxi gc0308.c (older but useful init tables)](https://github.com/allwinner-zh/linux-3.4-sunxi/blob/master/drivers/media/video/sunxi-vfe/device/gc0308.c)

### Related platform / memory notes

- [Portable HyperRAM controller (VHDL) – useful for understanding burst efficiency issues](https://github.com/MJoergen/HyperRAM)
- [HyperRAM controller documentation site](https://mjoergen.github.io/HyperRAM/)

**Bottom line for a hard grader:**\
&#x20;Your first image is not a success metric. A **correct** image is defined by: (1) register read-back matches intent, (2) 1280 bytes per HREF, (3) stable content in on-chip BRAM before any external memory or UART is involved. Everything else is secondary.

---

# پیوست C — گزارش Grok: Documented Failure Modes and Root-Cause Analysis

> **منبع:** گزارش Grok که در فایل موقت `gc0308_fpga_investigation_report_tang_nano_4k.md` در شاخه `CAMERA-LINE` قرار داده شده بود.
> **روش انتقال:** متن گزارش مستقل، بدون حذف جزئیات فنی، مثال‌ها، تحلیل‌ها و منابع، به این پیوست منتقل شده است. گزارش‌های قبلی موجود در همان فایل، پیش‌تر در پیوست‌های A و B سند حاضر ادغام شده بودند و دوباره تکثیر نشده‌اند.

---

\# FPGA-Based GC0308 Interface: Documented Failure Modes and Root-Cause Analysis\
\
\*\*Research scope note:\*\* This report prioritizes primary engineering evidence: forum threads with resolved outcomes, driver source commits, and register documentation. Findings are explicitly partitioned by evidence strength. Where the requested detail (a verified GC0308 + Tang Nano 4K + HyperRAM implementation) does not exist in accessible sources, that is stated rather than fabricated.\
\
\---\
\
\## 1. Executive Summary\
\
The most consequential finding for the user's project is that \*\*the dominant documented cause of severe color distortion and structured artifacts on the GC0308 is not sensor malfunction, but byte-level and format-level mismatches between what the sensor serializes and what the receiving logic assumes\*\*. Three specific failure modes recur across independent platforms:\
\
1\. \*\*YUV422 byte-order mismatch\*\* (YUYV vs. UYVY) produces a characteristic “green/purple” cast with a recognizable image silhouette—not random noise. The encoder/display side reads chroma as luma and vice versa. This is confirmed on ESP32-S3 with GC0308 and is a standard CSI debugging checkpoint on Allwinner platforms.\
\
2\. \*\*RGB565 big-endian serialization without byte-swap\*\* produces recognizable images with saturated false color, or severe banding if a byte-slip occurs. A GC0308 driver commit explicitly documents that on an 8-bit DVP bus, the \*\*high byte is clocked out first\*\*, yielding RGB565X (big-endian). An ESP32-CAM fix describes the exact signature: “odd byte lost in RGB565 swaps the bytes of every following pixel: recognisable image, saturated false colour.”\
\
3\. \*\*RGB444 output mode produces contour-like water-ripple artifacts\*\* that disappear entirely when switching to RGB565. This is an experimentally resolved case on a direct FPGA-to-display path, with the original engineer confirming the fix. The most plausible mechanism is that RGB444 packs 12 bits into a byte stream that the downstream logic misinterprets, generating structured quantization bands rather than uniform noise.\
\
A fourth finding directly relevant to the user's HyperRAM architecture: \*\*HyperRAM bandwidth limitation can cause visible tearing or banding when used as a real-time frame buffer\*\*, whereas on-chip RAM does not exhibit the artifact. This was documented on a Renesas platform, not with GC0308 specifically, but the architectural principle applies.\
\
No verified public implementation of GC0308 + Gowin Tang Nano 4K + HyperRAM was found. The Tang Nano 4K's documented DVP camera support is for OV2640, not GC0308. This does not mean the user's approach is infeasible, but it means the integration must be validated incrementally rather than by reference to a known-good design.\
\
\---\
\
\## 2. GC0308 Sensor Architecture and Output Formats (Confirmed GC0308-Specific)\
\
The GC0308 is a 640×480 (VGA) CMOS sensor with an active array of 648×488 pixels (the extra columns/rows serve ISP margins). It integrates an on-chip ISP performing Bayer interpolation, denoise, color correction, gamma correction, and format conversion. The digital output is via an 8-bit DVP (Digital Video Port) with PCLK, HREF (HSYNC), and VSYNC.\
\
\### 2.1 Output Format Register (0x24)\
\
The primary format selector is \*\*register 0x24, bits[3:0]\*\*. Verified mappings from Linux kernel and NuttX driver sources:\
\
\| Register 0x24 bits[3:0] | Output format | Media bus code / note | Source |\
\|---|---|---|---|\
\| \`0x02\` | YUYV (YCbCr422) | \`MEDIA_BUS_FMT_YUYV8_2X8\` | Linux GC0308 driver patch |\
\| \`0x03\` | YVYU (YCbCr422 variant) | \`MEDIA_BUS_FMT_YVYU8_2X8\` | Same |\
\| \`0x06\` | \*\*RGB565\*\* | \`MEDIA_BUS_FMT_RGB565_2X8_BE\` — \*\*big-endian\*\* | Same; NuttX commit |\
\| \`0x07\` | RGB555 | \`RGB555_2X8_PADHI_BE\` | Linux driver patch |\
\| \`0x09\` | RGB444 | \`RGB444_2X8_PADHI_BE\` | Linux driver patch |\
\| \`0xa2\` (full byte) | YCbYCr (YUV422) | Default in some SDKs | ARCS SDK default registers |\
\
\*\*Critical distinction:\*\* \`0x06\` selects RGB565, and the \`\_BE\` suffix in the media bus code is not incidental. A NuttX commit explicitly states: “On an 8-bit DVP bus the high byte is clocked out first, so the pixel data arrives in memory in big-endian order (RGB565X).” This means the byte sequence for one pixel is \`[R4:R0 G5:G3]\` then \`[G2:G0 B4:B0]\`, and a little-endian consumer that reads the two bytes as a 16-bit word will see the green bits split incorrectly and the color channels reversed in a structured way—not random noise.\
\
\### 2.2 Timing and Synchronization Polarity (Register 0x26)\
\
Register 0x26 bits[2:0] configure VSYNC/HREF/PCLK polarity. A documented example: when 0x26 = 0x01, VSYNC is high-active, HREF is low-active, and data is launched on the \*\*falling edge\*\* of PCLK. The receiving controller must then be configured with opposite sampling polarity (sample on rising edge if the sensor launches on falling, or vice versa, depending on the controller's convention). This is a common source of one-pixel horizontal shifts or duplicated/missing pixels at line boundaries.\
\
A Linux device-tree binding for GC0308 shows \`pclk-sample = <1>\` (sample on rising edge), indicating that rising-edge sampling is the default expectation for at least one integration. The user's FPGA must match whatever 0x26 is programmed to, and the PCLK edge used in the capture process must be verified against the actual launch edge, not assumed.\
\
\---\
\
\## 3. Documented FPGA / Embedded Interface Problems\
\
\### 3.1 RGB444 Mode → Contour-Like Water-Ripple Artifacts (Resolved, FPGA Path)\
\
\*\*Platform:\*\* FPGA directly driving a display from GC0308, no JPEG/H.264 compression. \*\*Problem:\*\* Image showed noise-like artifacts resembling contour lines or water ripples. \*\*Root cause identified by original engineer:\*\* Sensor was configured for RGB444 output. \*\*Solution:\*\* Changing the sensor output configuration to RGB565 eliminated the artifact; the engineer reported the image quality “became good” and the “contour-line water-ripple problem was solved.” \*\*Verification:\*\* Experimentally confirmed by the original poster.\
\
\*\*Relevance to the user:\*\* This is the single most directly applicable resolved case because it involves an FPGA receiving GC0308 data and displaying it. If the user's design has been experimented with “different output representations,” an RGB444 or RGB555 mode may have been engaged inadvertently, or the downstream packing logic may be treating a non-RGB565 stream as RGB565. The artifact described—structured contour bands, not uniform noise—matches the user's “posterization” and “structured image artifacts” description more closely than random FIFO corruption would.\
\
\### 3.2 YUV422 Byte-Order Mismatch → Green/Purple Cast with Recognizable Silhouette\
\
\*\*Platform:\*\* ESP32-S3 + GC0308 (CoreS3-Lite), with a JPEG encoder in the pipeline. \*\*Problem:\*\* Image outline correct, frame rate correct, resolution correct, but overall green or purple cast; white walls not white; faces cyan. White balance adjustment and resolution changes did not help. \*\*Root cause:\*\* The capture side declared one YUV422 byte order and the encoder side declared the other. The two conventions are:\
\
\| Convention | Four-byte sequence | Alias |\
\|---|---|---|\
\| Y-Cb-Y-Cr | Y₀, Cb, Y₁, Cr | YUY2 / YUYV |\
\| Cb-Y-Cr-Y | Cb, Y₀, Cr, Y₁ | UYVY |\
\
Both are “YUV422,” both have the same byte count, so \*\*no length error is raised\*\*. The decoder reads luma as chroma and chroma as luma, swapping the brightness and color channels. \*\*Solution:\*\* Ensure the format declaration on the capture side and the encoder/consumer side match exactly. The engineer provided a methodology: capture a frame of a white sheet and inspect the first 16 raw bytes to determine which byte positions carry luma vs. chroma.\
\
\*\*Relevance to the user:\*\* If the user's MATLAB reconstruction treats the received byte stream as YUV422 but the GC0308 is programmed for UYVY while MATLAB assumes YUYV (or vice versa), the exact symptom will be a tinted image with preserved geometry. This should be the first hypothesis tested if the image is recognizable but uniformly color-shifted.\
\
\### 3.3 RGB565 Byte-Slip → Recognizable Image with Saturated False Color (Resolved at Driver Level)\
\
\*\*Platform:\*\* ESP32-S3 + GC0308, VGA/RGB565, PSRAM DMA path. \*\*Problem:\*\* Frames exhibited a “byte-slip signature”: an odd byte was lost, causing \*\*every following pixel's bytes to be swapped\*\*. The result was a recognizable image with saturated false color. The driver did not warn because the DMA descriptor chain reported lengths that summed to less than the frame capacity, but the application still received the buffer as if complete. \*\*Root cause:\*\* DMA transfer stopped early, leaving trailing descriptors at zero length; the incomplete frame was silently delivered. \*\*Solution:\*\* Sum the descriptor lengths and drop the frame (\`en = 1\`) when they do not add up to the chain capacity, converting silent corruption into a visible dropped frame.\
\
\*\*Relevance to the user:\*\* The user's architecture includes a FIFO and HyperRAM. If the capture FIFO overflows or the HyperRAM write burst is interrupted—whether due to bandwidth contention, a clock-domain-crossing stall, or an address-generation bug—the resulting byte stream will be \*\*misaligned by one byte\*\*. In RGB565, this produces exactly the “swapped bytes of every following pixel” signature: colors become wildly saturated but the image remains geometrically recognizable. This is a \*\*critical\*\* hypothesis for the user's “severe posterization and color distortion” if the artifacts begin at a specific horizontal position or after a certain number of pixels.\
\
\### 3.4 PCLK Sampling Edge Mismatch → One-Pixel Shift / Line-Dependent Corruption\
\
\*\*Platform:\*\* Allwinner CSI (general principle, GC0308 named). \*\*Problem:\*\* Large areas of green and purple with normal outline. \*\*Root cause identified:\*\* (a) YUYV order mismatch, or (b) PCLK sampling edge wrong relative to the sensor's launch edge, causing data to be sampled at a transition. \*\*Solution:\*\* First verify YUYV order against the sensor spec; if correct, adjust the PCLK sampling edge.\
\
\*\*Relevance to the user:\*\* The GC0308 launches data on either the rising or falling edge depending on register 0x26. If the FPGA capture process samples on the same edge as the launch, setup/hold violations will cause intermittent bit errors that appear as line-dependent or position-dependent corruption. This is distinct from a byte-order issue: byte-order errors affect all pixels uniformly, whereas sampling-edge errors often vary with data pattern and trace delay.\
\
\### 3.5 Input Format Mismatch in Downstream ISP → Stripes (Non-FPGA, but Architecturally Instructive)\
\
\*\*Platform:\*\* NUC980 CSI. \*\*Problem:\*\* When a Y-only sensor was used but the controller was configured for RGB565 input, the image had stripes. \*\*Documented explanation:\*\* “If the input image format is RGB565, [the controller] will first convert to YUV422, which destroys the data.” The controller's internal path expected YUV422 and performed a conversion that was inappropriate for an RGB565 stream. The solution was to configure both INFMT and OUTFMT consistently as YUV422.\
\
\*\*Relevance to the user:\*\* This reinforces that \*\*format declarations at every stage of the pipeline must be consistent\*\*. If the user's FPGA capture controller inserts a format-conversion stage—or if the packing logic for HyperRAM storage assumes a different format than the sensor's register 0x24 setting—the data will be corrupted before it ever reaches MATLAB.\
\
\### 3.6 HyperRAM Bandwidth Limitation → Tearing / Banding in Real-Time Frame Buffering\
\
\*\*Platform:\*\* Renesas platform (not GC0308-specific). \*\*Problem:\*\* After moving camera input buffers to external HyperRAM, severe tearing appeared. \*\*Root cause:\*\* HyperRAM bandwidth was lower than required for the real-time display path. \*\*Recommended solution:\*\* Place real-time display buffers in on-chip RAM; use HyperRAM only for non-real-time data, or move only a portion of the display buffer to HyperRAM if on-chip capacity is insufficient.\
\
\*\*Relevance to the user:\*\* The Tang Nano 4K's HyperRAM is 64 Mb, 8-bit wide, with the Gowin datasheet listing a maximum operating frequency of 80 MHz for the hard memory controller. At 8 bits × 80 MHz, the theoretical peak is 80 MB/s (640 Mb/s). A 640×480 RGB565 frame at 30 fps requires approximately 18.4 MB/s, which is within peak bandwidth, but \*\*real-time capture and readback contend for the same bus\*\*, and HyperRAM has significant latency for random-access and bank-crossing patterns. If the capture FIFO drains to HyperRAM while the UART readback is simultaneously fetching a previous frame, the effective write bandwidth can collapse, causing FIFO overflow and the byte-slip corruption described in 3.3. This is a structural risk in the user's architecture, not a hypothetical one.\
\
\### 3.7 Unresolved Community Cases (No Confirmed Root Cause)\
\
Several forum threads describe color errors with RGB565 that were never resolved by the original posters:\
\
\- OpenEdv thread (STM32F407 + GC0308, RGB565 320×240): “color incorrect, RGB big/little endian confirmed should be correct”; multiple users reported the same problem, no resolution posted. Another user in the same thread reported “many stripes” in the image and could not find a byte-swap bit in the GC0308 datasheet.\
\- OpenEdv thread (STM32F407): “image color parsing is always wrong, tried all output modes, none correct,” with an attached RGB565 image showing data corruption. No root cause was confirmed.\
\- 51hei thread: “image outline roughly correct but color wrong, overall dark,” no resolution posted.\
\
These unresolved cases are important because they demonstrate that \*\*“endianness confirmed correct” by the developer is not equivalent to “byte stream verified by inspection of raw data.”\*\* In the absence of a raw-byte capture, developers frequently misidentify the source of the mismatch.\
\
\---\
\
\## 4. Color Distortion and Posterization: Root-Cause Ranking for This Project\
\
The table below ranks hypotheses by \*\*specificity to the GC0308 + FPGA + HyperRAM architecture\*\* and by the \*\*availability of corroborating primary evidence\*\*.\
\
\| Rank | Hypothesis | Expected visual signature | Corroborating evidence | How to falsify |\
\|---|---|---|---|---|\
\| \*\*1\*\* | \*\*RGB565 big-endian output not byte-swapped for MATLAB\*\* | Recognizable image, saturated/reversed colors; uniform across frame | NuttX commit explicitly documents RGB565X big-endian output on 8-bit DVP | Capture one frame to a file; inspect bytes for a known uniform-color object; check whether swapping every two bytes yields plausible RGB565 |\
\| \*\*2\*\* | \*\*YUV422 byte-order mismatch (YUYV vs. UYVY)\*\* | Green/purple or cyan/magenta cast; geometry intact; luma/chroma swapped | ESP32-S3 resolved case with byte-level methodology; Allwinner CSI debugging checkpoint | Same raw-byte inspection: determine whether Y or Cb occupies byte 0 of each four-byte group |\
\| \*\*3\*\* | \*\*FIFO overflow / HyperRAM write stall → byte-slip\*\* | Corruption begins at a specific column or after a burst of pixels; subsequent pixels have swapped bytes → saturated false color | ESP32-CAM byte-slip signature is identical; HyperRAM bandwidth warning documented | Reduce PCLK frequency or insert wait states to eliminate overflow; if artifact disappears, bandwidth/FIFO is causal |\
\| \*\*4\*\* | \*\*PCLK sampling edge wrong\*\* | Intermittent bit errors, often line-dependent or data-pattern-dependent; not uniform across all pixels | Allwinner guidance: adjust PCLK sampling edge after YUYV check | Use a logic analyzer or ILA to compare PCLK edge vs. data transitions; try opposite edge |\
\| \*\*5\*\* | \*\*RGB444 or RGB555 mode inadvertently selected\*\* | Contour-like water-ripple bands, “posterization” appearance | Resolved FPGA case: RGB444 caused contour artifacts; RGB565 fixed it | Read register 0x24 back via I2C/SCCB after initialization; confirm bits[3:0] = 0x06 for RGB565 |\
\| \*\*6\*\* | \*\*Sensor register 0x24 misconfigured for a different format than MATLAB assumes\*\* | Could produce any of the above depending on actual vs. assumed format | Register 0x24 mapping verified | Same: read back 0x24 and compare to the format assumed in MATLAB reconstruction |\
\
\*\*Why hypothesis 5 is ranked above a pure “sensor problem”:\*\* The user reports having experimented with “RGB565, YUV422, Grayscale” and modified packing/buffering. If a previous build left the sensor in RGB444 or RGB555 mode and only the MATLAB side was changed, the resulting mismatch would produce structured bands that could easily be misattributed to “posterization” from bit-depth truncation. The resolved FPGA case confirms this is a real failure mode on a direct FPGA path.\
\
\---\
\
\## 5. Successful GC0308 Implementations and What They Did Differently\
\
\### 5.1 NuttX GC0308 Driver (RGB565X Reporting)\
\
The NuttX commit changes the reported pixel format from \`V4L2_PIX_FMT_RGB565\` to \`V4L2_PIX_FMT_RGB565X\` when register 0x24 is set to \`0x06\`. The commit message states the reason explicitly: the high byte is clocked out first on the 8-bit DVP bus, so memory layout is big-endian. The driver then allows userspace to detect this and byte-swap if needed for a little-endian display path. The key differentiator is \*\*explicit format reporting based on the sensor's actual serialization order\*\*, not an assumption that “RGB565” means little-endian 16-bit words.\
\
\### 5.2 Linux Mainline GC0308 Driver (Format Enumeration)\
\
The Linux driver defines distinct media bus codes for YUYV (\`0x02\`), YVYU (\`0x03\`), RGB565 big-endian (\`0x06\`), RGB555 (\`0x07\`), and RGB444 (\`0x09\`). By enumerating these as separate formats rather than a single “RGB565” label, the driver prevents the exact ambiguity that causes byte-order mismatches. It also defines \`GC0308_OUT_FORMAT\` at register \`0x024\` and configures format dynamically in \`start_capture()\` based on the requested pixel format.\
\
\### 5.3 ESP32-S3 Byte-Order Fix (Software Reconstruction)\
\
The CoreS3-Lite case resolved a green/purple cast by aligning the capture-side and encoder-side YUV422 byte-order declarations. The engineer emphasized that both sides must declare the same four-byte sequence and provided a raw-frame-header inspection method. This is a successful reconstruction because the fix was verified against the observable artifact, not just against a register value.\
\
\### 5.4 “Milink” FPGA Tutorial Series (SDRAM Frame Buffer, Not HyperRAM)\
\
Chinese FPGA training materials reference a GC0308 camera + SDRAM frame buffer + HDMI output example, and a Sobel edge-detection example. However, \*\*no source code or register initialization sequence was accessible\*\* in the search results, and these examples use SDRAM, not HyperRAM. They are noted as existence proofs of GC0308 + FPGA frame-buffer pipelines, but they cannot be used to validate the user's HyperRAM architecture or byte-order handling.\
\
\### 5.5 What Is Notably Absent\
\
No public, verified implementation of \*\*GC0308 + Gowin Tang Nano 4K + HyperRAM + UART + MATLAB\*\* was found. The Tang Nano 4K's documented camera support is for OV2640. This absence does not invalidate the user's approach, but it means the HyperRAM timing, Gowin-specific FIFO IP behavior, and UART bandwidth constraints must be validated from first principles rather than by copying a known-good design.\
\
\---\
\
\## 6. FIFO and External Memory Architecture: Specific Risks in This Design\
\
The user's pipeline is:\




که مال دیپ سیک هست و&#x20;
