/* dev/climb/homeacl.c — homeacl <dir> <uuid>: set <dir>'s ACL to exactly one entry, <uuid> allowed list, search,
   readattr, readextattr and readsecurity, inherited by every file and directory made under it: the ACE
   dev/climb/setup-users.sh gives each build user's home (Dale's read), set again by the home's owner on every use
   (door.clean, R7-5). The owner may set its own home's ACL, but a door run has no Mach bootstrap (nobootstrap.c), so
   chmod +a cannot translate a name to its UUID (probed: "Unable to translate 'daleblack' to a UUID"): the UUID is given,
   and the entry is built by the acl(3) calls that take it as it is. Precedent: chmod(1)'s own ACL path, without its
   name lookup. */
#include <stdio.h>
#include <string.h>
#include <sys/acl.h>
#include <uuid/uuid.h>
int main(int argc, char **argv) {
    uuid_t u;
    if (argc != 3 || uuid_parse(argv[2], u) != 0) { fprintf(stderr, "homeacl <dir> <uuid>\n"); return 64; }
    acl_t acl = acl_init(1);
    acl_entry_t e;
    acl_permset_t ps;
    acl_flagset_t fs;
    if (!acl || acl_create_entry(&acl, &e) || acl_set_tag_type(e, ACL_EXTENDED_ALLOW) || acl_set_qualifier(e, u) ||
        acl_get_permset(e, &ps) || acl_get_flagset_np(e, &fs)) { perror("homeacl: an entry"); return 70; }
    acl_perm_t perms[] = {ACL_LIST_DIRECTORY, ACL_SEARCH, ACL_READ_ATTRIBUTES, ACL_READ_EXTATTRIBUTES, ACL_READ_SECURITY};
    for (size_t i = 0; i < sizeof perms / sizeof perms[0]; i++) acl_add_perm(ps, perms[i]);
    acl_add_flag_np(fs, ACL_ENTRY_FILE_INHERIT); acl_add_flag_np(fs, ACL_ENTRY_DIRECTORY_INHERIT);
    if (acl_set_permset(e, ps) || acl_set_flagset_np(e, fs) || acl_set_file(argv[1], ACL_TYPE_EXTENDED, acl)) {
        perror("homeacl: acl_set_file"); return 70;
    }
    acl_free(acl);
    return 0;
}
