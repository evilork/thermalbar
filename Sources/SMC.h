// SMC.h - read-only access to the System Management Controller.
// Used for GPU temperature (Tg* keys), whole-system power (PSTR) and fans.
// Works without sudo on Apple Silicon. All calls are serialized and thread-safe.
#ifndef THERMALBAR_SMC_H
#define THERMALBAR_SMC_H

/// Opens the SMC connection. Returns 1 on success, 0 when the SMC is unavailable.
int tb_smc_open(void);

/// Number of keys the SMC exposes, or 0 on failure.
int tb_smc_key_count(void);

/// Writes the 4-character name of key `index` plus a NUL into `out`. Returns 1 on success.
int tb_smc_key_at(int index, char out[5]);

/// Looks up the data type (four-char code) and size of `key`. Returns 1 on success.
int tb_smc_key_info(const char *key, unsigned int *type, unsigned int *size);

/// Reads a numeric key whose type and size are already known. NAN on failure or unsupported type.
double tb_smc_read_known(const char *key, unsigned int type, unsigned int size);

/// Reads a numeric key (looks the type up first). NAN on failure.
double tb_smc_read(const char *key);

/// Four-char code of a 4-character string, e.g. "flt ".
unsigned int tb_smc_fourcc(const char *code);

/// Closes the SMC connection (call on quit).
void tb_smc_close(void);

#endif
