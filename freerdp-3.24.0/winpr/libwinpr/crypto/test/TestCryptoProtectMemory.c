
#include <winpr/crt.h>
#include <winpr/print.h>
#include <winpr/crypto.h>
#include <winpr/ssl.h>
#include <winpr/wlog.h>

static const char* SECRET_PASSWORD_TEST = "MySecretPassword123!";

int TestCryptoProtectMemory(int argc, char* argv[])
{
	int rc = -1;
	UINT32 cbPlainText = 0;
	UINT32 cbCipherText = 0;
	const char* pPlainText = nullptr;
	BYTE* pCipherText = nullptr;

	WINPR_UNUSED(argc);
	WINPR_UNUSED(argv);

	pPlainText = SECRET_PASSWORD_TEST;
	cbPlainText = strlen(pPlainText) + 1;
	cbCipherText = cbPlainText +
	               (CRYPTPROTECTMEMORY_BLOCK_SIZE - (cbPlainText % CRYPTPROTECTMEMORY_BLOCK_SIZE));
	printf("cbPlainText: %" PRIu32 " cbCipherText: %" PRIu32 "\n", cbPlainText, cbCipherText);
	pCipherText = (BYTE*)malloc(cbCipherText);
	if (!pCipherText)
	{
		printf("Unable to allocate memory\n");
		return -1;
	}
	CopyMemory(pCipherText, pPlainText, cbPlainText);
	ZeroMemory(&pCipherText[cbPlainText], (cbCipherText - cbPlainText));
	if (!winpr_InitializeSSL(WINPR_SSL_INIT_DEFAULT))
		goto fail;

	if (!CryptProtectMemory(pCipherText, cbCipherText, CRYPTPROTECTMEMORY_SAME_PROCESS))
	{
		printf("CryptProtectMemory failure\n");
		goto fail;
	}

	printf("PlainText: %s (cbPlainText = %" PRIu32 ", cbCipherText = %" PRIu32 ")\n", pPlainText,
	       cbPlainText, cbCipherText);
	winpr_HexDump("crypto.test", WLOG_DEBUG, pCipherText, cbCipherText);

	if (!CryptUnprotectMemory(pCipherText, cbCipherText, CRYPTPROTECTMEMORY_SAME_PROCESS))
	{
		printf("CryptUnprotectMemory failure\n");
		goto fail;
	}

	printf("Decrypted CipherText: %s\n", pCipherText);
	SecureZeroMemory(pCipherText, cbCipherText);

	rc = 0;
fail:
	free(pCipherText);
	return rc;
}
