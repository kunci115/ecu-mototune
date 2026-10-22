# Cara dump ECU di rumah (tanpa internet di Mac)

1. Tutup app aRacer X Tune di HP (swipe close), biar bridge bebas.
2. Nyalakan kontak motor supaya ECU dan Wi-Fi bridge hidup.
3. Di Mac: System Settings → Wi-Fi → join SSID bridge aRacer (password yang biasa dipakai di app).
   Kalau macOS bilang "No Internet Connection", biarkan, jangan pindah jaringan.
4. Buka Terminal, jalankan:

       cd ~/Documents/Projects/aracer-xtune-re
       python3 ecu_dump.py

   Kalau calibration key pernah diganti di app:  python3 ecu_dump.py --key ANGKANYA

5. Tunggu sampai muncul "== SELESAI". Biasanya 5–10 menit. Kalau berhenti dengan error, tidak apa-apa,
   folder dumps/ tetap berguna.
6. Pindahkan Wi-Fi Mac kembali ke internet, buka sesi Claude Code di folder ini, dan bilang
   "dump sudah ada". Semua hasil ada di dumps/<tanggal-jam>/.

Yang skrip ini lakukan: hanya membaca. Satu-satunya perintah non-baca adalah unlock
calibration key (sama seperti app resmi tiap connect) dan on/off live stream.

## Catatan kecepatan

Waktu dump ditentukan oleh latensi Wi-Fi ke bridge (sekitar 8 ms per request), bukan CPU Mac.
Skrip sudah mengirim 16 request sekaligus (pipelining). Kalau ECU/bridge terlihat tidak stabil,
turunkan: `python3 ecu_dump.py --window 4`. Kalau stabil dan mau lebih cepat lagi coba `--window 32`.

## Uji stream saja (cepat, ~20 detik)

Kalau dump tabel sudah ada dan cuma mau cek data live:

```
cd ~/Documents/Projects/aracer-xtune-re
python3 ecu_dump.py --quick
```

## Versi Swift (fondasi app iOS)

Folder `ARacerKit/` berisi library protokol dalam Swift beserta test yang memakai frame asli ECU kamu.
Uji ke ECU asli (Mac join Wi-Fi ECU, app aRacer di HP ditutup):

```
cd ~/Documents/Projects/aracer-xtune-re/ARacerKit
swift run aracer-cli identify
swift run aracer-cli quick
```

## Dashboard (macOS, tanpa Xcode)

```
cd ~/Documents/Projects/aracer-xtune-re/ARacerKit
swift run ARacerDash --demo     # lihat tampilannya dengan data simulasi, tanpa motor
swift run ARacerDash            # ke ECU asli: Mac join Wi-Fi ECU, lalu klik "Hubungkan"
```
Kalau koneksi putus, app menyambung ulang sendiri. Tampilan ini sama dengan yang nanti dipakai di iPhone.

## Tabel tuning (sudah bisa dilihat sekarang, dari dump)

`swift run ARacerDash --demo` lalu buka tab **Tabel**. Isinya tabel asli ECU kamu (Fuel, Spark, Target AFR,
Inj angle, RPM limit=12000, dll) sebagai grid angka mentah. Skala dan label sumbu belum ada: itu tersimpan
di file definisi terenkripsi yang tidak kita buka. Cara memberi arti tiap sel: ubah satu sel di app aRacer
resmi, simpan, dump ulang, bandingkan. Dari selisihnya ketahuan skala & sumbu per tabel, pasti benar untuk ECU kamu.
