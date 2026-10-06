package com.vortex.vortexcam

import android.app.Activity
import android.nfc.NfcAdapter
import android.nfc.cardemulation.HostApduService
import android.nfc.tech.IsoDep
import android.os.Bundle
import android.util.Log

/**
 * Pair a camera by TOUCHING the switcher (plan: NFC as an alternative to the QR, 2026-10-06).
 * The switcher answers as an NFC card (Host Card Emulation, [PairingHceService]) holding the same pairing JSON as its
 * QR (room address + its own network's name and password); the camera reads it in reader mode and follows the same
 * path as a scanned QR. Android Beam no longer exists, so HCE ↔ reader mode is the phone-to-phone way.
 *
 * Wire format (ISO 7816-4 APDUs): SELECT by [AID] → 90 00; READ BINARY `00 B0 <offset hi> <offset lo> <len>` →
 * up to [CHUNK] bytes of the UTF-8 JSON + 90 00 (empty + 90 00 past the end); 6A 82 when no switcher is advertising.
 */
object NfcPairing {
    private const val TAG = "NfcPairing"
    /** Proprietary AID (F0 = RID not registered): "SMBA" + version 1. */
    val AID = byteArrayOf(0xF0.toByte(), 0x53, 0x4D, 0x42, 0x41, 0x01)
    const val CHUNK = 200
    private val OK = byteArrayOf(0x90.toByte(), 0x00)
    private val NOT_FOUND = byteArrayOf(0x6A, 0x82.toByte())

    /** What this phone gives when touched (the switcher sets it while its screen is open; null = nothing). */
    @Volatile var payload: ByteArray? = null

    fun available(a: Activity): Boolean = NfcAdapter.getDefaultAdapter(a) != null
    fun enabled(a: Activity): Boolean = NfcAdapter.getDefaultAdapter(a)?.isEnabled == true

    /** Card side: one APDU in, one out. */
    fun answer(apdu: ByteArray): ByteArray {
        if (apdu.size >= 4 && apdu[1] == 0xA4.toByte()) {                                  // SELECT
            val lc = if (apdu.size > 4) apdu[4].toInt() and 0xFF else 0
            val aid = if (apdu.size >= 5 + lc) apdu.copyOfRange(5, 5 + lc) else ByteArray(0)
            return if (aid.contentEquals(AID) && payload != null) OK else NOT_FOUND
        }
        if (apdu.size >= 4 && apdu[1] == 0xB0.toByte()) {                                  // READ BINARY
            val p = payload ?: return NOT_FOUND
            val off = ((apdu[2].toInt() and 0xFF) shl 8) or (apdu[3].toInt() and 0xFF)
            if (off >= p.size) return OK
            return p.copyOfRange(off, minOf(p.size, off + CHUNK)) + OK
        }
        return NOT_FOUND
    }

    /** Reader side: while on, touching a switcher calls [onPayload] with its pairing JSON (on a binder thread). */
    fun startReader(a: Activity, onPayload: (String) -> Unit) {
        val nfc = NfcAdapter.getDefaultAdapter(a) ?: return
        val flags = NfcAdapter.FLAG_READER_NFC_A or NfcAdapter.FLAG_READER_NFC_B or NfcAdapter.FLAG_READER_SKIP_NDEF_CHECK
        nfc.enableReaderMode(a, { tag ->
            val iso = IsoDep.get(tag) ?: return@enableReaderMode
            try {
                iso.connect(); iso.timeout = 2000
                val sel = byteArrayOf(0x00, 0xA4.toByte(), 0x04, 0x00, AID.size.toByte()) + AID + byteArrayOf(0x00)
                if (!iso.transceive(sel).endsWith(OK)) { Log.i(TAG, "not a Samba switcher"); return@enableReaderMode }
                val out = java.io.ByteArrayOutputStream()
                while (out.size() < 8192) {
                    val off = out.size()
                    val r = iso.transceive(byteArrayOf(0x00, 0xB0.toByte(), (off shr 8).toByte(), off.toByte(), CHUNK.toByte()))
                    if (!r.endsWith(OK) || r.size == 2) break
                    out.write(r, 0, r.size - 2)
                }
                val json = out.toString("UTF-8")
                Log.i(TAG, "read ${json.length} chars from the switcher")
                if (json.isNotEmpty()) onPayload(json)
            } catch (e: Exception) {
                Log.w(TAG, "read failed: ${e.message}")
            } finally { try { iso.close() } catch (_: Exception) {} }
        }, flags, Bundle())
    }

    fun stopReader(a: Activity) { try { NfcAdapter.getDefaultAdapter(a)?.disableReaderMode(a) } catch (_: Exception) {} }

    private fun ByteArray.endsWith(t: ByteArray) =
        size >= t.size && copyOfRange(size - t.size, size).contentEquals(t)
}

/** The switcher's NFC "card" (declared in the manifest with res/xml/samba_apdu.xml). */
class PairingHceService : HostApduService() {
    override fun processCommandApdu(apdu: ByteArray, extras: Bundle?): ByteArray = NfcPairing.answer(apdu)
    override fun onDeactivated(reason: Int) {}
}
