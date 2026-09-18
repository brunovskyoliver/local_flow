package prompts

import (
	"crypto/sha256"
	"fmt"
	"testing"
)

// Each version's content hash is immutable. Add a version entry when changing
// instructions; do not replace an existing version's hash.
func TestVersionedTemplates(t *testing.T) {
	hashes := map[string]map[int]string{
		"clean":    {1: "b3a833cd6dbd539b2277278a200fcd7b55abe193df1353412c074a89dc1bc1f7", 2: "346286e325385a6e739679878ecc278b530c87eedcc1d4fe7d2b6ada72518d04", 3: "6f163546eb9f06d1efbf11cc3b72e5be36529389b9b3dba0a17605002d79bc47", 4: "7d1358ebb7dd416d52017266e1ef2907ddfb11193c614bed91b51fe53b939743", 5: "6758c353aac79135e64e2d5284e859695bd55ee751b86d200b171c96f353d1be"},
		"polished": {1: "9299470bc8994c821db60d99c2aee37f769b2f2f1a05ba0c61aacf65dce307b0", 2: "2d216a6b524b357f6b6f595eca011d57662420cf1543660876d2ecf2cf96c061", 3: "ab5d6c4ff980ee1f8df294ce33e01f9ec7da808a0b89e78e177ebc632c0023dc"},
		"concise":  {1: "31f85e89fea9bfe632be91b3e884c1833a9b141f2487acb38f167bb631b528d7", 2: "5b00814078526c1b2453c1d11cf97e46ca785787d9525b4727005d0d976c3bf9", 3: "9818ab41f926b87a15120cf7c9c664f3823471cb382e24786be62fd39b43b338"},
	}
	for mode, template := range templates {
		if got := fmt.Sprintf("%x", sha256.Sum256([]byte(template.Text))); hashes[mode][template.Version] != got {
			t.Errorf("%s v%d unregistered template hash: %s", mode, template.Version, got)
		}
	}
}
