#include "workspace_fids.h"
#include "workspace_grants_abi.h"
#include <cstdio>
#include <thread>
#include <atomic>
#include <functional>
using dsh::WorkspaceFid;
int checks=0;void check(bool b,const char*label){printf("%s %s\n",b?"PASS":"FAIL",label);if(!b)exit(1);++checks;}
void rejects(std::function<void()> op,const char* code){try{op();check(false,code);}catch(const dsh::GrantError&e){check(e.code==code,code);}}
int main(int argc,char**argv){if(argc!=2)return 2;std::string path=argv[1];mkdir(path.c_str(),0700);int rootfd=open(path.c_str(),O_RDONLY|O_DIRECTORY);auto& owner=dsh::WorkspaceGrantOwner();owner.Publish("g",1,rootfd,true);
 const std::string ticket(64,'a');check(dsh_workspace_ticket_issue(ticket.c_str(),"g",1,1)==0,"issue RW task");
 auto lease=std::shared_ptr<dsh::WorkspaceLease>(static_cast<dsh::WorkspaceLease*>(dsh_workspace_ticket_consume(ticket.c_str())));check(bool(lease),"consume once");check(!dsh_workspace_ticket_consume(ticket.c_str()),"second consume denied");
 auto root=WorkspaceFid::Root(lease);auto f=root->Create("file");f->Write(0,"original");auto walked=root->Walk("file");root->Rename("file",*root,"held");auto replacement=root->Create("file");replacement->Write(0,"replaced");walked->Open(false);check(walked->Read(0,8)=="original","walk keeps original inode after replacement");
 auto old=root->Walk("held");root->Rename("held",*root,"old");auto fresh=root->Create("held");fresh->Write(0,"safe");rejects([&]{old->Open(true,true);},"ERR_WORKSPACE_OBJECT_REPLACED");check(fresh->Read(0,4)=="safe","replacement not truncated");f->Write(0,"PINNED!!");check(walked->Read(0,8)=="PINNED!!","opened descriptor stays same inode after rename");
 symlinkat("/tmp",rootfd,"escape");try{root->Walk("escape");check(false,"symlink");}catch(const std::system_error&){check(true,"symlink blocked");}rejects([&]{root->Walk("a/b");},"ERR_WORKSPACE_PATH");check(root->Walk("..")==root,"root parent clamped");root->Mkdir("dir");auto dir=root->Walk("dir");check(dir->Walk("..")==root,"parent stays logical object");check(root->List().size()==5,"real directory enumeration");
 auto ro=WorkspaceFid::Root(std::shared_ptr<dsh::WorkspaceLease>(owner.Acquire("g",1,false)));rejects([&]{ro->Create("denied");},"ERR_WORKSPACE_READ_ONLY");ro.reset();
 check(dsh_workspace_ticket_retire(ticket.c_str())==0,"retire admission retains live FID debt");rejects([&]{root->Walk("file");},"ERR_WORKSPACE_TASK_RETIRED");rejects([&]{f->Write(0,"bad");},"ERR_WORKSPACE_TASK_RETIRED");lease.reset();root.reset();check(dsh_workspace_ticket_retire(ticket.c_str())==0,"last child pins admission");f.reset();walked.reset();replacement.reset();old.reset();fresh.reset();dir.reset();check(dsh_workspace_ticket_retire(ticket.c_str())==1,"last clunk drains admission");
 auto status=owner.Retire("g",1);check(status.drained,"generation drains");owner.Publish("g",2,rootfd,true);rejects([&]{owner.Acquire("g",1,true);},"ERR_WORKSPACE_GENERATION");auto next=WorkspaceFid::Root(std::shared_ptr<dsh::WorkspaceLease>(owner.Acquire("g",2,true)));auto nextfile=next->Walk("file");nextfile->Open(true);owner.Retire("g",2);rejects([&]{nextfile->Read(0,8);},"ERR_WORKSPACE_RETIRED");check(!owner.Status("g",2).drained,"revoked existing FID still owns lease");nextfile.reset();next.reset();check(owner.Status("g",2).drained,"clunk old revoked FID releases");close(rootfd);printf("TOTAL %d PASS\n",checks);
}
