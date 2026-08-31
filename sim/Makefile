ROOT_DIR := $(realpath ..)
include $(ROOT_DIR)/config.mk

all: simx rtlsim opaesim xrtsim

simx:
	$(MAKE) -C simx

rtlsim:
	$(MAKE) -C rtlsim

opaesim:
	$(MAKE) -C opaesim

xrtsim:
	$(MAKE) -C xrtsim

# Not in `all`: needs a VCS installation and a license.
xrtsim_vcs:
	$(MAKE) -C xrtsim_vcs

clean:
	$(MAKE) -C simx clean
	$(MAKE) -C rtlsim clean
	$(MAKE) -C opaesim clean
	$(MAKE) -C xrtsim clean
	$(MAKE) -C xrtsim_vcs clean

.PHONY: all simx rtlsim opaesim xrtsim xrtsim_vcs clean