from nacl.signing import SigningKey
import hashlib

# 1. Generate a new random private key
sk = SigningKey.generate()
pk = sk.verify_key

# 2. Save the private key OFFLINE (don't git add this!)
with open("../metadata/private_key.bin", "wb") as f:
    f.write(sk.encode())
print("private key saved")

# 3. Save the public key (this goes in your repo)
with open("../metadata/public_key.bin", "wb") as f:
    f.write(pk.encode())
print("public key saved")

# 4. Generate the Hash for your Chisel OTP
# This is what you hardcode into your Chisel RTL
otp_hash_bytes = hashlib.sha256(pk.encode()).digest()  # raw bytes

with open("../metadata/pubkey_hash.bin", "wb") as f:
    f.write(otp_hash_bytes)
print(f"Pubkey hash saved")