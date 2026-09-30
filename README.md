# Mine-imator Custom + HCl Edition: upload ke GitHub

Sama seperti kit sebelumnya:
1. Buat repository GitHub baru.
2. Upload SEMUA file di folder ini ke halaman utama repo (termasuk .gitattributes).
3. Ubah nama `build-windows.yml` menjadi `.github/workflows/build-windows.yml`.
4. Tab Actions > Build Mine-imator Custom + HCl Windows > Run workflow.
5. Unduh artifact `Mine-imator-Custom-HCL-Win64-Candidate`, jalankan `START-CUSTOM.cmd`.

Build pertama membangun Qt dari source dan bisa lama. Kalau gagal, unduh artifact `Mine-imator-build-logs` dan kirim ke sini.

BELUM PERNAH dikompilasi di Windows. Gravitasi lama dihapus; fisika memakai panel PHYSICS bawaan HCl.
