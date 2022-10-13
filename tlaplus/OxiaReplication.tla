-------------------------- MODULE OxiaReplication --------------------------
EXTENDS MessagePassing, Integers, Sequences, FiniteSets, TLC

(*

Each action has ample comments that describe it. Also each action is
clearly commented to show what the enabling conditions are and what
the state changes are. Enabling conditions are the conditions required
for the action to take place, such as an epoch being of the right value.
An action wil only occur if all the enabling conditions are true.

This spec includes:
- One or more operators
- Multiple nodes
- Leader election
- Data replication
- Reconfiguration
    - Swapping one node for another
    - Expanding the cluster (increasing rep factor)
    - Contracting the cluster (decreasing rep factor)
    - Handling failed/stalled reconfigurations

Not modelling:
- Failure detection. There is no need to as:
    - the coordinator can start an election at any time.
    - for each election, the coordinator has visibility of any arbitrary number of nodes which
      simulates an arbitray number of node failures.
      
The state space is large as expected. Use of simulation for non-trivial numbers of nodes, values
and epochs is required.      
*)

CONSTANTS Operators,         \* The set of all operators (should only be one but the protocol should handle multiple)
          Nodes,             \* The set of all nodes
          Values,            \* The set of all values that can be sent by clients
          RepFactor          \* The desired initial replication factor
          
\* State space          
CONSTANTS MaxEpochs,         \* The max number of epochs for the model checker to explore
          MaxOperatorStops   \* The max number of operator crashes that the model checker will explore

\* Shard statuses
CONSTANTS STEADY_STATE,      \* The shard is in data replication mode
          ELECTION,          \* An election is in progress
          RECONFIGURATION    \* A reconfiguration operation is in progress

\* Operator statuses
CONSTANTS RUNNING,           \* an operator is running
          NOT_RUNNING        \* an operator is not running

\* Node statuses
CONSTANTS FENCED,            \* denotes a node that has been fenced during an election
          LEADER,            \* denotes a chosen leader
          FOLLOWER,          \* denotes a follower ready to receive entries from the leader
          NOT_MEMBER         \* not a member of the shard ensemble

\* Election phases
CONSTANTS FENCING,           \* prevent nodes from making progress
          NOTIFY_LEADER,     \* a leader has been selected and is being notified by the operator
          LEADER_ELECTED     \* a leader has confirmed its leadership        

\* Reconfiguration ops
CONSTANTS NODE_SWAP,         \* one node is being swapped out for another
          EXPAND,            \* the shard ensemble is being increased by one node
          CONTRACT           \* the shard ensemble is being reduced by one node

\* Reconfiguration phases
CONSTANTS PREPARE,           \* preparation phase (coping of snapshots, fencing)
          COMMIT             \* commit phase (operator and leader commits the change)

\* return codes
CONSTANTS OK,                \* the request was serviced correctly
          INVALID_EPOCH      \* node has rejected a request because it has a higher epoch than the request
                    
\* follow cursor states
CONSTANTS ATTACHED,          \* a follow cursor is attached and operational
          PENDING_TRUNCATE,  \* a follow cursor is inactive but will become active upon follower truncation
          PENDING_REMOVAL    \* a follow cursor is inactive and will be removed on reconfig commit

\* other model values
CONSTANTS NIL                \* used in various places to signify something does not exist

VARIABLES 
          \* state of the system
          metadata_version,  \* monotonic counter incremented on each metadata change   
          metadata,          \* the metadata shard state
          node_state,        \* the nodes and their state
          operator_state,    \* the operators and their state
          
          \* auxilliary state required by the spec
          confirmed,         \* the confirmation status of each written value
          operator_stop_ctr  \* a counter that incremented each time an operator crashes/stops

vars == << metadata_version, metadata, node_state, operator_state, confirmed, messages, operator_stop_ctr >>
view == << metadata_version, metadata, node_state, operator_state, confirmed, messages >>

(* -----------------------------------------
   TYPE DEFINITIONS
  
  The type definitions for the fundamental structures, messages
  and state of the various actors. Required for the optional type invariant
  TypeOK and also useful to understand the structure of the protocol. 
  ----------------------------------------- *)

\* Basic types
Epoch == 0..MaxEpochs
NodesOrNil == Nodes \union {NIL}
EntryId == [offset: Nat, epoch: Epoch]
LogEntry == [entry_id: EntryId, value: Values]
CursorStatus == { NIL, ATTACHED, PENDING_TRUNCATE, PENDING_REMOVAL }
Cursor == [status: CursorStatus, last_pushed: EntryId, last_confirmed: EntryId]
NodeStatus == { LEADER, FOLLOWER, FENCED, NOT_MEMBER }
ReconfigOps == { NODE_SWAP, EXPAND, CONTRACT }

\* equivalent of null for various record types
NoEntryId == [offset |-> 0, epoch |-> 0]
NoLogEntry == [entry_id |-> NoEntryId, value |-> NIL]
NoCursor == [status |-> NIL, last_pushed |-> NoEntryId, last_confirmed |-> NoEntryId]

\* ------------------------------
\* Messages
\* ------------------------------

\* Operator -> Nodes
FenceRequest ==
    [type:     {FENCE_REQUEST},
     node:     Nodes,
     operator: Operators,
     epoch:    Epoch]

\* Node -> Operator
FenceResponse == 
    [type:       {FENCE_RESPONSE},
     node:       Nodes,
     operator:   Operators,
     head_index: EntryId,
     epoch:      Epoch]

\* Operator -> Node
BecomeLeaderRequest ==
    [type:         {BECOME_LEADER_REQUEST},
     node:         Nodes,
     operator:     Operators,
     epoch:        Epoch,
     rep_factor:   Nat,
     follower_map: [Nodes -> EntryId \union {NIL}]]

\* Node -> Operator
BecomeLeaderResponse ==
    [type:     {BECOME_LEADER_RESPONSE},
     node:     Nodes,
     operator: Operators,
     epoch:    Epoch]

\* Operator -> Node (Leader)
AddFollowerRequest ==
    [type:       {ADD_FOLLOWER_REQUEST},
     node:       Nodes,
     follower:   Nodes,
     head_index: EntryId,
     epoch:      Epoch]

\* Node (Leader) -> Node (Follower)     
TruncateRequest ==
    [type:        {TRUNCATE_REQUEST},
     dest_node:   Nodes,
     source_node: Nodes,
     epoch:       Epoch,
     head_index:  EntryId]

\* Node (Follower) -> Node (Leader)     
TruncateResponse ==
    [type:        {TRUNCATE_RESPONSE},
     dest_node:   Nodes,
     source_node: Nodes,
     epoch:       Epoch,
     head_index:  EntryId]
     
\* Node (Leader) -> Node (Follower)
AddEntryRequest ==
    [type:         {ADD_ENTRY_REQUEST},
     dest_node:    Nodes,
     source_node:  Nodes,
     entry:        LogEntry,
     commit_index: EntryId,
     epoch:        Epoch]

\* Node (Follower) -> Node (Leader)      
AddEntryResponse ==
    [type:        {ADD_ENTRY_RESPONSE},
     dest_node:   Nodes,
     source_node: Nodes,
     code:        {OK, INVALID_EPOCH},
     entry_id:    EntryId,
     epoch:       Epoch]

\* Operator -> Node (Leader)
PrepareReconfigRequest ==
    [type:     {PREPARE_RECONFIG_REQUEST},
     op:       {NODE_SWAP}, 
     epoch:    Epoch,
     node:     Nodes,
     operator: Operators,
     old_node: Nodes] 
        \union
    [type:     {PREPARE_RECONFIG_REQUEST},
     op:       {EXPAND}, 
     epoch:    Epoch,
     node:     Nodes,
     operator: Operators]
        \union
    [type:     {PREPARE_RECONFIG_REQUEST},
     op:       {CONTRACT}, 
     epoch:    Epoch,
     node:     Nodes,
     operator: Operators,
     old_node: Nodes]

\* Node (Leader) -> Operator
PrepareReconfigResponse ==
    [type:         {PREPARE_RECONFIG_RESPONSE},
     op:           {NODE_SWAP, EXPAND}, 
     epoch:        Epoch,
     node:         Nodes,
     operator:     Operators,
     snapshot:     SUBSET LogEntry,
     head_index:   EntryId,
     commit_index: EntryId]
        \union
    [type:     {PREPARE_RECONFIG_RESPONSE},
     op:       {CONTRACT},
     epoch:    Epoch,
     node:     Nodes,
     operator: Operators]

\* Operator -> Node (New Follower)     
SnapshotRequest ==
    [type:         {SNAPSHOT_REQUEST},
     node:         Nodes,
     operator:     Operators,
     epoch:        Epoch,
     snapshot:     SUBSET LogEntry,
     head_index:   EntryId,
     commit_index: EntryId]

\* Node (New Follower) -> Operator
SnapshotResponse ==
    [type:       {SNAPSHOT_RESPONSE},
     node:       Nodes,
     operator:   Operators,
     epoch:      Epoch,
     head_index: EntryId]

\* Operator -> Node (Leader)
CommitReconfigRequest ==
    [type:       {COMMIT_RECONFIG_REQUEST},
     op:         {NODE_SWAP},
     node:       Nodes,
     operator:   Operators,
     epoch:      Epoch,
     rep_factor: Nat,
     old_node:   Nodes,
     new_node:   Nodes,
     head_index: EntryId]
        \union
    [type:       {COMMIT_RECONFIG_REQUEST},
     op:         {EXPAND},
     node:       Nodes,
     operator:   Operators,
     epoch:      Epoch,
     rep_factor: Nat,
     new_node:   Nodes,
     head_index: EntryId]
        \union
    [type:       {COMMIT_RECONFIG_REQUEST},
     op:         {CONTRACT},
     node:       Nodes,
     operator:   Operators,
     epoch:      Epoch,
     rep_factor: Nat,
     old_node:   Nodes]

\* Node (Leader) -> Operator
CommitReconfigResponse ==
    [type:     {COMMIT_RECONFIG_RESPONSE},
     op:       {NODE_SWAP},
     node:     Nodes,
     operator: Operators,
     epoch:    Epoch,
     old_node: Nodes,
     new_node: Nodes]
        \union
    [type:     {COMMIT_RECONFIG_RESPONSE},
     op:       {EXPAND},
     node:     Nodes,
     operator: Operators,
     epoch:    Epoch,
     new_node: Nodes]
        \union
    [type:     {COMMIT_RECONFIG_RESPONSE},
     op:       {CONTRACT},
     node:     Nodes,
     operator: Operators,
     epoch:    Epoch,
     old_node: Nodes]
     
Message ==
    FenceRequest \union FenceResponse \union
    BecomeLeaderRequest \union BecomeLeaderResponse \union
    AddFollowerRequest \union
    TruncateRequest \union TruncateResponse \union
    AddEntryRequest \union AddEntryResponse \union
    PrepareReconfigRequest \union PrepareReconfigResponse \union 
    SnapshotRequest \union SnapshotResponse \union
    CommitReconfigRequest \union CommitReconfigResponse

\* Metadata store state
ShardStatus == { NIL, STEADY_STATE, ELECTION, RECONFIGURATION }
ReconfigPhase == { PREPARE, COMMIT }
ReconfigMetadata == 
    [phase:               ReconfigPhase,
     op:                  {NODE_SWAP},
     epoch:               Epoch, 
     rep_factor:          Nat,
     old_node:            Nodes,
     new_node:            Nodes,
     new_node_head_index: EntryId]
        \union
    [phase:               ReconfigPhase,
     op:                  {EXPAND},
     epoch:               Epoch, 
     rep_factor:          Nat,
     new_node:            Nodes,
     new_node_head_index: EntryId]
        \union
    [phase:               ReconfigPhase,
     op:                  {CONTRACT},
     epoch:               Epoch, 
     rep_factor:          Nat,
     old_node:            Nodes]
        \union {NIL}    
     
Metadata == [shard_status: ShardStatus,
             epoch:        Epoch,
             ensemble:     SUBSET Nodes,
             rep_factor:   Nat,
             leader:       NodesOrNil,
             reconfig:     ReconfigMetadata]

\* Node and Operator state
NodeState == [id:              Nodes,
              status:          NodeStatus,
              epoch:           Epoch,
              leader:          Nodes \union {NIL},
              rep_factor:      Nat,
              log:             SUBSET LogEntry,
              commit_index:    EntryId,
              head_index:      EntryId,
              follow_cursor:   [Nodes -> Cursor],
              reconfig_inprog: BOOLEAN]

OperatorStatuses == {NOT_RUNNING, RUNNING}
ElectionPhases == { NIL, FENCING, NOTIFY_LEADER, LEADER_ELECTED }
OperatorState == [id:                        Operators,
                  status:                    OperatorStatuses,
                  md_version:                Nat,
                  md:                        Metadata \union {NIL},
                  election_phase:            ElectionPhases,
                  election_fencing_ensemble: SUBSET Nodes,
                  election_final_ensemble:   SUBSET Nodes,
                  election_leader:           Nodes \union {NIL},
                  election_fence_responses:  SUBSET FenceResponse]
                  
\* Type invariant                  
TypeOK ==
    /\ metadata \in Metadata
    /\ node_state \in [Nodes -> NodeState]
    /\ operator_state \in [Operators -> OperatorState]
    /\ \A v \in DOMAIN confirmed :
        /\ v \in Values
        /\ confirmed[v] \in BOOLEAN
    /\ \A msg \in DOMAIN messages : msg \in Message


(* -----------------------------------------
   INITIAL STATE
 
   The only initial state is the shard ensemble
   and rep factor. There is no leader, followers
   or even a running operator.
   -----------------------------------------
*)

Init ==
    LET ensemble == CHOOSE e \in SUBSET Nodes : Cardinality(e) = RepFactor
    IN
        /\ metadata_version = 0
        /\ metadata = [shard_status |-> NIL,
                       epoch        |-> 0,
                       ensemble     |-> ensemble,
                       rep_factor   |-> RepFactor,
                       leader       |-> NIL,
                       reconfig     |-> NIL]
        /\ node_state = [n \in Nodes |-> 
                            [id              |-> n,
                             status          |-> NOT_MEMBER,
                             epoch           |-> 0,
                             leader          |-> NIL,
                             rep_factor      |-> 0,
                             log             |-> {},
                             commit_index    |-> NoEntryId,
                             head_index      |-> NoEntryId,
                             follow_cursor   |-> [n1 \in Nodes |-> NoCursor],
                             reconfig_inprog |-> FALSE]]
                             
        /\ operator_state = [o \in Operators |->
                            [id                        |-> o,
                             status                    |-> NOT_RUNNING,
                             md_version                |-> 0,
                             md                        |-> NIL,
                             election_phase            |-> NIL,
                             election_fencing_ensemble |-> {},
                             election_final_ensemble   |-> {},
                             election_leader           |-> NIL,
                             election_fence_responses  |-> {}]]
        /\ confirmed = <<>>
        /\ messages = <<>>
        /\ operator_stop_ctr = 0

(* -----------------------------------------
   HELPER OPERATORS
   -----------------------------------------*) 

\* Does this set of nodes consistitute a quorum?    
IsQuorum(nodes, ensemble) ==
    Cardinality(nodes) >= (Cardinality(ensemble) \div 2) + 1
    
\* Compare two entry ids:
\*  entry_id1 > entry_id2 = 1
\*  entry_id1 = entry_id2 = 0
\*  entry_id1 < entry_id2 = -1
CompareLogEntries(entry_id1, entry_id2) ==
    IF entry_id1.epoch > entry_id2.epoch THEN 1
    ELSE
        IF entry_id1.epoch = entry_id2.epoch /\ entry_id1.offset > entry_id2.offset THEN 1
        ELSE
            IF entry_id1.epoch = entry_id2.epoch /\ entry_id1.offset = entry_id2.offset THEN 0
            ELSE -1

IsLowerId(entry_id1, entry_id2) ==
    CompareLogEntries(entry_id1, entry_id2) = -1
    
IsLowerOrEqualId(entry_id1, entry_id2) ==
    CompareLogEntries(entry_id1, entry_id2) \in {-1, 0}    
    
IsHigherId(entry_id1, entry_id2) ==
    CompareLogEntries(entry_id1, entry_id2) = 1
    
IsHigherOrEqualId(entry_id1, entry_id2) ==
    CompareLogEntries(entry_id1, entry_id2) \in {0, 1}    
    
IsSameId(entry_id1, entry_id2) ==
    CompareLogEntries(entry_id1, entry_id2) = 0

HeadEntry(log) ==
    IF log = {}
    THEN NoLogEntry
    ELSE CHOOSE entry \in log :
        \A e \in log : IsHigherOrEqualId(entry.entry_id, e.entry_id)

(*---------------------------------------------------------
  Operator starts
  
  The operator loads the metadata from the metadata store.
  The metadata will decide what the operator might do
  next, such as continue a reconfiguration that was in-progress
  when it crashed.
----------------------------------------------------------*)

OperatorStarts ==
    \* enabling conditions
    /\ \E o \in Operators :
        /\ operator_state[o].status = NOT_RUNNING
        \* state changes
        /\ operator_state' = [operator_state EXCEPT ![o] = 
            [id                        |-> o,
             status                    |-> RUNNING,
             md_version                |-> metadata_version,
             md                        |-> metadata,
             election_phase            |-> NIL,
             election_fencing_ensemble |-> {},
             election_final_ensemble   |-> {},
             election_leader           |-> NIL,
             election_fence_responses  |-> {}]]
        /\ UNCHANGED << confirmed, metadata, metadata_version, node_state, messages, operator_stop_ctr >> 
             
(*---------------------------------------------------------
  Operator stops
  
  The operator crashes/stops and loses all local state.
----------------------------------------------------------*)

OperatorStops ==
    \* enabling conditions
    /\ operator_stop_ctr < MaxOperatorStops
    /\ \E o \in Operators :
        /\ operator_state[o].status = RUNNING
        \* state changes
        /\ operator_state' = [operator_state EXCEPT ![o].status                    = NOT_RUNNING,
                                                    ![o].md_version                = 0,
                                                    ![o].md                        = NIL,
                                                    ![o].election_phase            = NIL,
                                                    ![o].election_fencing_ensemble = {},
                                                    ![o].election_final_ensemble   = {},
                                                    ![o].election_leader           = NIL,
                                                    ![o].election_fence_responses  = {}]
        /\ operator_stop_ctr' = operator_stop_ctr + 1
        /\ OperatorMessagesLost(o)
        /\ UNCHANGED << confirmed, metadata, metadata_version, node_state >>
             

(*---------------------------------------------------------
  Operator starts an election
  
  In reality this will be triggered by some kind of failure
  detection outside the scope of this spec. This
  spec simply allows the operator to decide to start an
  election at anytime.
  
  The first phase of an election is for the operator to
  ensure that the shard cannot make progress by fencing
  a majority of nodes and getting their head index.
  
  Key points:
  - An election increments the epoch of the shard.
  - The election has two different ensembles:
        a) the fencing ensemble
        b) the final ensemble 
    The reason for this is that an election may be resolving a
    stuck reconfiguration that is in the commit phase. 
    Specifically either a Node Swap or an Expand operation but
    not a Contract operation.
     
    If a reconfiguration is in the commit phase this means that 
    the previous operator had started the commit phase but may 
    or may not have been able to complete it. If an election 
    doesn't take this into account it is possible to end up with 
    two majority clusters both able to make progress. To avoid 
    this, a fencing ensemble will include a node which may or 
    may not have been added to the cluster in a reconfiguration 
    op that did not complete.
    
    Upon receiving a fence response from a majority of the fencing
    ensemble, the operator sets the final ensemble to match
    the result of the reconfiguration ensemble change. This completes
    the reconfiguration.    
    
  - The message passing module assumes all sent messages are
    retried until abandoned by the sender. To simulate some nodes not 
    responding during an election, a non-deterministic subset of the fencing
    ensemble that constitutes an majority is used, this simulates
    message loss and dead nodes of a minority.
    
  - In this spec, updating the metadata in the metadata store and sending
    fencing requests is one atomic action. In an implementation, the
    metadata would need to be updated first, then the fencing requests sent.
    
  - The election phases are local state for the operator only. The only
    required state in the metadata is the epoch and that an election is
    in-progress. If the operator were to fail at any time during an
    election then the next operator that starts would see the ELECTION 
    status in the metadata and trigger a new election.
    
  - The metadata update will fail if the version does not match the version
    held by the operator.
----------------------------------------------------------*)

GetFenceRequests(o, new_epoch, ensemble) ==
    { [type     |-> FENCE_REQUEST,
       node     |-> n,
       operator |-> o,
       epoch    |-> new_epoch] : n \in ensemble }

\* include the new node of an in-progress reconfig
FencingEnsemble ==
    IF /\ metadata.reconfig # NIL 
       /\ metadata.reconfig.phase = COMMIT
       /\ metadata.reconfig.op \in { NODE_SWAP, EXPAND }
    THEN metadata.ensemble \union { metadata.reconfig.new_node }
    ELSE metadata.ensemble

OperatorStartsElection ==
    \* enabling conditions
    \E o \in Operators :
        LET ostate           == operator_state[o]
            fencing_ensemble == FencingEnsemble
        IN 
            /\ metadata.epoch < MaxEpochs \* state space reduction
            /\ ostate.status = RUNNING
            /\ ostate.md_version = metadata_version
            /\ \E visible_nodes \in SUBSET fencing_ensemble :
                /\ IsQuorum(visible_nodes, fencing_ensemble)
                \* state changes
                /\ LET new_epoch      == ostate.md.epoch + 1
                       new_metadata   == [metadata EXCEPT !.epoch        = new_epoch,
                                                          !.shard_status = ELECTION,
                                                          !.leader       = NIL,
                                                          !.reconfig     = IF @ # NIL /\ @.phase = COMMIT
                                                                           THEN @
                                                                           ELSE NIL]
                       new_md_version == metadata_version + 1                                             
                   IN
                       /\ metadata_version' = new_md_version
                       /\ metadata' = new_metadata
                       /\ operator_state' = [operator_state EXCEPT ![o].id                        = o,
                                                                   ![o].md_version                = new_md_version,
                                                                   ![o].md                        = new_metadata,
                                                                   ![o].election_phase            = FENCING,
                                                                   ![o].election_fencing_ensemble = fencing_ensemble,
                                                                   ![o].election_final_ensemble   = {},
                                                                   ![o].election_leader           = NIL,
                                                                   ![o].election_fence_responses  = {}]
                       /\ SendMessages(GetFenceRequests(o, new_epoch, ostate.md.ensemble))     
    /\ UNCHANGED << node_state, confirmed, operator_stop_ctr >>
           

(*---------------------------------------------------------
  Node handles a fence request
  
  A node receives a fencing request, fences itself and responds 
  with its head index.
  
  When a node is fenced it cannot:
  - accept any writes from a client.
  - accept add entry requests from a leader.
  - send any entries to followers if it was a leader.
  
  Any existing follow cursors are destroyed as is any state
  regarding reconfigurations.
----------------------------------------------------------*)              
GetFenceResponse(nstate, new_epoch, o) ==
    [type           |-> FENCE_RESPONSE,
     node           |-> nstate.id,
     operator       |-> o,
     head_index     |-> nstate.head_index,
     epoch          |-> new_epoch]

NodeHandlesFencingRequest ==
    \* enabling conditions
    \E msg \in DOMAIN messages :
        /\ ReceivableMessageOfType(messages, msg, FENCE_REQUEST)
        /\ LET nstate == node_state[msg.node]
           IN /\ nstate.epoch < msg.epoch
              \* state changes
              /\ node_state' = [node_state EXCEPT ![msg.node] =
                                    [@ EXCEPT !.epoch           = msg.epoch,
                                              !.status          = FENCED,
                                              !.rep_factor      = 0,
                                              !.follow_cursor   = [n \in Nodes |-> NoCursor],
                                              !.reconfig_inprog = FALSE]]
              /\ ProcessedOneAndSendAnother(msg, GetFenceResponse(nstate, msg.epoch, msg.operator))  
              /\ UNCHANGED << metadata, metadata_version, operator_state, confirmed, operator_stop_ctr >>


(*---------------------------------------------------------
  Operator handles fence response not yet reaching quorum
  
  The operator handles a fence response but has not reached 
  quorum yet so simply stores the response.
----------------------------------------------------------*)

OperatorHandlesPreQuorumFencingResponse ==
    \* enabling conditions
    \E o \in Operators :
        LET ostate == operator_state[o]
        IN
            /\ ostate.status = RUNNING
            /\ ostate.md.shard_status = ELECTION
            /\ ostate.election_phase = FENCING 
            /\ \E msg \in DOMAIN messages :
                /\ ReceivableMessageOfType(messages, msg, FENCE_RESPONSE)
                /\ msg.operator = o
                /\ ostate.md.epoch = msg.epoch
                /\ LET fenced_res    == ostate.election_fence_responses \union { msg }
                   IN /\ ~IsQuorum(fenced_res, ostate.election_fencing_ensemble)
                      \* state changes
                      /\ operator_state' = [operator_state EXCEPT ![o].election_fence_responses = fenced_res]
                      /\ MessageProcessed(msg)
                      /\ UNCHANGED << metadata, metadata_version, node_state, confirmed, operator_stop_ctr >>

(*---------------------------------------------------------
  Operator handles fence response reaching quorum
  
  The operator handles a fencing response and reaches 
  majority quorum. It selects the node with the highest head 
  index and sends it a "become leader" request which
  contains a {follower->head index} map and the current rep
  factor.
  
  The final ensemble is also determined at this point. If
  there is a reconfiguration process (NODE_SWAP or EXPAND)
  that is in the commit phase that did not complete at
  the time of the election, then the ensemble change of
  that reconfiguration is set now.
----------------------------------------------------------*)
FinalElectionEnsemble(ostate, responses) ==
    IF /\ ostate.md.reconfig # NIL
       /\ ostate.md.reconfig.phase = COMMIT
       /\ ostate.md.reconfig.op \in { NODE_SWAP, EXPAND }
    THEN IF ostate.md.reconfig.op = NODE_SWAP
         THEN (ostate.md.ensemble \ {ostate.md.reconfig.old_node}) 
                    \union {ostate.md.reconfig.new_node}
         ELSE ostate.md.ensemble \union {ostate.md.reconfig.new_node}
    ELSE ostate.md.ensemble

FollowerResponse(responses, f) ==
    CHOOSE r \in responses : r.node = f

GetFollowerMap(ostate, leader, responses, final_ensemble) ==
    LET followers == { f \in final_ensemble :
                        /\ f # leader
                        /\ \E r \in responses : r.node = f }
    IN  [f \in Nodes |->
            IF f \in followers
            THEN FollowerResponse(responses, f).head_index
            ELSE NIL]
   
GetBecomeLeaderRequest(n, epoch, o, follower_map, rep_factor) ==
    [type         |-> BECOME_LEADER_REQUEST,
     node         |-> n,
     operator     |-> o,
     follower_map |-> follower_map,
     rep_factor   |-> rep_factor,
     epoch        |-> epoch]

WinnerResponse(responses, final_ensemble) ==
    CHOOSE r1 \in responses :
        /\ r1.node \in final_ensemble
        /\ ~\E r2 \in responses :
            /\ IsHigherId(r2.head_index, r1.head_index)
            /\ r2.node \in final_ensemble  
    
OperatorHandlesQuorumFencingResponse ==
    \* enabling conditions
    \E o \in Operators :
        LET ostate == operator_state[o]
        IN
            /\ ostate.status = RUNNING
            /\ ostate.md.shard_status = ELECTION
            /\ ostate.election_phase = FENCING 
            /\ \E msg \in DOMAIN messages :
                /\ ReceivableMessageOfType(messages, msg, FENCE_RESPONSE)
                /\ msg.operator = o
                /\ ostate.md.epoch = msg.epoch
                /\ LET fenced_res          == ostate.election_fence_responses \union { msg }
                       final_ensemble      == FinalElectionEnsemble(ostate, fenced_res)
                       max_head_res        == WinnerResponse(fenced_res, final_ensemble)
                       new_leader          == max_head_res.node
                       last_epoch_entry_id == max_head_res.head_index
                       follower_map        == GetFollowerMap(ostate, new_leader, fenced_res, final_ensemble) 
                   IN
                      /\ IsQuorum(fenced_res, ostate.election_fencing_ensemble)
                      \* state changes 
                      /\ operator_state' = [operator_state EXCEPT ![o] = 
                                                [@ EXCEPT !.election_phase           = NOTIFY_LEADER,
                                                          !.election_leader          = new_leader,
                                                          !.election_final_ensemble  = final_ensemble,
                                                          !.election_fence_responses = fenced_res]]
                      /\ ProcessedOneAndSendAnother(msg, 
                                                    GetBecomeLeaderRequest(new_leader, 
                                                                           ostate.md.epoch, 
                                                                           o,
                                                                           follower_map,
                                                                           ostate.md.rep_factor))
                      /\ UNCHANGED << metadata, metadata_version, node_state, confirmed, operator_stop_ctr >>    

(*---------------------------------------------------------
  Node handles a Become Leader request
  
  The node inspects the head index of each follower and
  compares it to its own head index, and then either:
  - Attaches a follow cursor for the follower the head indexes
    have the same epoch, but the follower offset is lower or equal.
  - Sends a truncate request to the follower if its head
    index epoch does not match the leader's head index epoch or has
    a higher offset.
    The leader finds the highest entry id in its log prefix (of the
    follower head index) and tells the follower to truncate it's log 
    to that entry.
    
  Key points:
  - The election only requires a majority to complete and so the
    Become Leader request will likely only contain a majority,
    not all the nodes.
  - No followers in the Become Leader message "follower map" will 
    have a higher head index than the leader (as the leader was
    chosen because it had the highest head index of the majority
    that responded to the fencing requests first). But as the leader
    receives more fencing responses from the remaining minority,
    the new leader will be informed of these followers and it is 
    possible that their head index is higher than the leader and
    therefore need truncating.
----------------------------------------------------------*)

GetHighestEntryOfEpoch(nstate, target_epoch) ==
    IF \E entry \in nstate.log : entry.entry_id.epoch <= target_epoch
    THEN CHOOSE entry \in nstate.log :
        /\ entry.entry_id.epoch <= target_epoch
        /\ \A e \in nstate.log : 
            \/ e.entry_id.epoch > target_epoch
            \/ /\ e.entry_id.epoch <= target_epoch
               /\ IsHigherOrEqualId(entry.entry_id, e.entry_id)
    ELSE NoLogEntry

NeedsTruncation(nstate, head_index) ==
    \/ /\ head_index.epoch = nstate.head_index.epoch
       /\ head_index.offset > nstate.head_index.offset
    \/ head_index.epoch # nstate.head_index.epoch
    
GetCursor(nstate, head_index) ==
    IF NeedsTruncation(nstate, head_index)
    THEN [status         |-> PENDING_TRUNCATE,
          last_pushed    |-> NoEntryId,
          last_confirmed |-> NoEntryId] 
    ELSE [status         |-> ATTACHED,
          last_pushed    |-> head_index,
          last_confirmed |-> head_index]

GetCursors(nstate, follower_map) ==
    [n \in Nodes |->
         IF follower_map[n] # NIL 
         THEN GetCursor(nstate, follower_map[n]) 
         ELSE NoCursor]


GetTruncateRequest(nstate, follower, target_epoch) ==
    [type        |-> TRUNCATE_REQUEST,
     dest_node   |-> follower,
     source_node |-> nstate.id,
     head_index  |-> GetHighestEntryOfEpoch(nstate, target_epoch).entry_id,
     epoch       |-> nstate.epoch] 

FollowersToTruncate(nstate, follower_map) ==
    { f \in DOMAIN follower_map : 
            /\ follower_map[f] # NIL
            /\ NeedsTruncation(nstate, follower_map[f]) }

GetTruncateRequests(nstate, follower_map) ==
    {
        GetTruncateRequest(nstate, f, follower_map[f].epoch) 
            : f \in FollowersToTruncate(nstate, follower_map)
    }

GetBecomeLeaderResponse(n, epoch, o) ==
    [type     |-> BECOME_LEADER_RESPONSE,
     epoch    |-> epoch,
     node     |-> n,
     operator |-> o]

NodeHandlesBecomeLeaderRequest ==
    \* enabling conditions
    \E msg \in DOMAIN messages :
        /\ ReceivableMessageOfType(messages, msg, BECOME_LEADER_REQUEST)
        /\ node_state[msg.node].epoch = msg.epoch
        /\ LET truncate_requests == GetTruncateRequests(node_state[msg.node], msg.follower_map)
               leader_response   == GetBecomeLeaderResponse(msg.node, msg.epoch, msg.operator)
               updated_cursors   == GetCursors(node_state[msg.node], msg.follower_map)
           IN
              \* state changes
              /\ node_state' = [node_state EXCEPT ![msg.node] =
                                          [@ EXCEPT !.status        = LEADER,
                                                    !.leader        = msg.node,
                                                    !.rep_factor    = msg.rep_factor,
                                                    !.follow_cursor = updated_cursors]]
              /\ ProcessedOneAndSendMore(msg, truncate_requests \union {leader_response})
              /\ UNCHANGED << metadata, metadata_version, operator_state, confirmed, operator_stop_ctr >>

(*---------------------------------------------------------
  Operator handles Become Leader response
  
  The election is completed on receiving the Become Leader
  response. The operator updates the metadata with the
  new leader, the ensemble and that the shard is now back 
  in steady state.
  
  The election is only able to complete if the metadata
  hasn't been modified since the beginning of the election.
  Any concurrent change will cause this election to fail.
    
  Key points:
  - The election may be resolving a reconfiguration operation
    that got stuck in the commit phase (or was being carried 
    out by another operator and is in the commit phase).
    The operator commits such a reconfiguration by updating
    the metadata with the ensemble change the reconfiguration
    was performing.
  - A minority of followers may still not have been fenced yet.
    The operator will continue to try to fence these followers
    forever until either they respond with a fencing request,
    or a new election/reconfiguration is performed. 
----------------------------------------------------------*)

OperatorHandlesBecomeLeaderResponse ==
    \* enabling conditions
    \E o \in Operators :
        LET ostate == operator_state[o]
        IN
            /\ ostate.status = RUNNING
            /\ ostate.md.shard_status = ELECTION
            /\ \E msg \in DOMAIN messages :
                /\ ReceivableMessageOfType(messages, msg, BECOME_LEADER_RESPONSE)
                /\ msg.operator = o
                /\ ostate.election_phase = NOTIFY_LEADER
                /\ ostate.md.epoch = msg.epoch
                /\ metadata_version = ostate.md_version
                \* state changes
                /\ LET new_md   == [ostate.md EXCEPT !.shard_status = STEADY_STATE,
                                                     !.leader       = msg.node,
                                                     !.ensemble     = ostate.election_final_ensemble,
                                                     !.rep_factor   = Cardinality(ostate.election_final_ensemble),
                                                     !.reconfig     = NIL]
                   IN /\ operator_state' = [operator_state EXCEPT ![o].election_phase = LEADER_ELECTED,
                                                                  ![o].md_version     = metadata_version + 1,
                                                                  ![o].md             = new_md]
                      /\ metadata' = new_md
                      /\ metadata_version' = metadata_version + 1
                      /\ MessageProcessed(msg)
                      /\ UNCHANGED << node_state, confirmed, operator_stop_ctr >>

(*---------------------------------------------------------
  Operator handles post quorum fence response
  
  The operator handles a fencing response at a time after
  it has selected a new leader. The leader must have confirmed
  its leadership before the opertator acts on any late 
  follower fence responses.
  
  Each fence response will translate to an Add Follower
  request being sent to the leader, including the follower's
  head index.
----------------------------------------------------------*)

GetAddFollowerRequest(n, epoch, follower, head_index) ==
    [type       |-> ADD_FOLLOWER_REQUEST,
     node       |-> n,
     follower   |-> follower,
     head_index |-> head_index,
     epoch      |-> epoch]

OperatorHandlesPostQuorumFencingResponse ==
    \* enabling conditions
    \E o \in Operators :
        LET ostate == operator_state[o]
        IN
            /\ ostate.status = RUNNING
            /\ ostate.election_phase = LEADER_ELECTED 
            /\ \E msg \in DOMAIN messages :
                /\ ReceivableMessageOfType(messages, msg, FENCE_RESPONSE)
                /\ msg.operator = o
                /\ msg.node \in ostate.md.ensemble \* might be the old_node
                /\ ostate.md.epoch = msg.epoch
                \* state changes
                /\ operator_state' = [operator_state EXCEPT ![o].election_fence_responses = @ \union {msg}]
                /\ ProcessedOneAndSendAnother(msg, 
                                              GetAddFollowerRequest(ostate.election_leader, 
                                                                    ostate.md.epoch, 
                                                                    msg.node,
                                                                    msg.head_index))
            /\ UNCHANGED << metadata, metadata_version, node_state, confirmed, operator_stop_ctr >>

(*---------------------------------------------------------
  Leader handles an Add Follower request
  
  The leader creates a cursor and will send a truncate
  request to the follower if their log might need
  truncating first.
----------------------------------------------------------*)

LeaderHandlesAddFollowerRequest ==
    \* enabling conditions
    \E msg \in DOMAIN messages :
        /\ ReceivableMessageOfType(messages, msg, ADD_FOLLOWER_REQUEST)
        /\ node_state[msg.node].epoch = msg.epoch
        /\ node_state[msg.node].status = LEADER
        /\ node_state[msg.node].follow_cursor[msg.follower].status = NIL
        \* state changes
        /\ node_state' = [node_state EXCEPT ![msg.node].follow_cursor[msg.follower] =
                                GetCursor(node_state[msg.node], msg.head_index)]
        /\ IF NeedsTruncation(node_state[msg.node], msg.head_index)
           THEN ProcessedOneAndSendAnother(msg, 
                                           GetTruncateRequest(node_state[msg.node],
                                                              msg.follower,
                                                              msg.head_index.epoch))
           ELSE MessageProcessed(msg)
        /\ UNCHANGED << metadata, metadata_version, operator_state, confirmed, operator_stop_ctr >>
                            

(*---------------------------------------------------------
  Node handles a Truncate request
  
  A node that receives a truncate request knows that it
  has been selected as a follower. It truncates its log
  to the indicates entry id, updates its epoch and changes
  to a Follower.
----------------------------------------------------------*)

GetTruncateResponse(msg, head_index) ==
    [type        |-> TRUNCATE_RESPONSE,
     dest_node   |-> msg.source_node,
     source_node |-> msg.dest_node,
     head_index  |-> head_index,
     epoch       |-> msg.epoch]

TruncateLog(log, last_safe_entry_id) ==
    { entry \in log : IsLowerOrEqualId(entry.entry_id, last_safe_entry_id) }

NodeHandlesTruncateRequest ==
    \* enabling conditions
    \E msg \in DOMAIN messages :
        /\ ReceivableMessageOfType(messages, msg, TRUNCATE_REQUEST)
        /\ LET nstate        == node_state[msg.dest_node]
               truncated_log == TruncateLog(nstate.log, msg.head_index)
               head_entry    == HeadEntry(truncated_log)
           IN
                /\ nstate.status = FENCED
                /\ nstate.epoch = msg.epoch
                \* state changes
                /\ node_state' = [node_state EXCEPT ![msg.dest_node] =
                                        [@ EXCEPT !.status        = FOLLOWER,
                                                  !.epoch         = msg.epoch,
                                                  !.leader        = msg.source_node,
                                                  !.log           = truncated_log,
                                                  !.head_index    = head_entry.entry_id,
                                                  !.follow_cursor = [n \in Nodes |-> NoCursor]]]
                /\ ProcessedOneAndSendAnother(msg, GetTruncateResponse(msg, head_entry.entry_id))
                /\ UNCHANGED << metadata, metadata_version, operator_state, confirmed, operator_stop_ctr >>

(*---------------------------------------------------------
  Leader handles a truncate response.
  
  The leader now activates the follow cursor as the follower
  log is now ready for replication.
----------------------------------------------------------*)

LeaderHandlesTruncateResponse ==
    \* enabling conditions
    \E msg \in DOMAIN messages :
        /\ ReceivableMessageOfType(messages, msg, TRUNCATE_RESPONSE)
        /\ LET nstate == node_state[msg.dest_node]
           IN
                /\ nstate.status = LEADER
                /\ nstate.epoch = msg.epoch
                \* state changes
                /\ node_state' = [node_state EXCEPT ![msg.dest_node].follow_cursor = 
                                        [@ EXCEPT ![msg.source_node] = [status         |-> ATTACHED,
                                                                        last_pushed    |-> msg.head_index,
                                                                        last_confirmed |-> msg.head_index]]]
                /\ MessageProcessed(msg)
                /\ UNCHANGED << metadata, metadata_version, operator_state, confirmed, operator_stop_ctr >>

(*---------------------------------------------------------
  A client writes an entry to the leader
  
  A client writes a value from Values to a leader node 
  if that value has not previously been written. The leader adds 
  the entry to its log, updates its head_index.  
----------------------------------------------------------*)
       
Write ==
    \* enabling conditions
    \E n \in Nodes, v \in Values :
        LET nstate == node_state[n]
        IN 
            /\ node_state[n].status = LEADER
            /\ v \notin DOMAIN confirmed
            \* state changes
            /\ LET entry_id  == [offset |-> nstate.head_index.offset + 1,
                                 epoch  |-> nstate.epoch]
                   log_entry == [entry_id |-> entry_id,
                                 value    |-> v]  
               IN
                    /\ node_state' = [node_state EXCEPT ![n] = 
                                        [@ EXCEPT !.log        = @ \union { log_entry },
                                                  !.head_index = entry_id]]
                    /\ confirmed' = confirmed @@ (v :> FALSE)
            /\ UNCHANGED << metadata, metadata_version, operator_state, metadata, messages, operator_stop_ctr >>


(*---------------------------------------------------------
  A leader node sends entries to followers
  
  The leader will send an entry to a follower when it has 
  entries in its log that is higher than the follow cursor 
  position of that follower. In this action, the leader
  will send the next entry for all followers whose cursor is
  lower then the leader's head index.
  
  This action chooses the largest subset of followers that
  have an attached cursor and whose cursor is behind the head
  of the leaders log. This is a state space reduction
  strategy as if we can send multiple requests at the same
  time we reduce the number of ways we send messages thus
  reducing the state space.
----------------------------------------------------------*)

CanSendToFollower(lstate, follower) ==
    /\ node_state[follower].status # NOT_MEMBER
    /\ follower # lstate.id
    /\ lstate.follow_cursor[follower].status = ATTACHED
    /\ IsHigherId(lstate.head_index, lstate.follow_cursor[follower].last_pushed)

\* does this group of followers include all followers that we can send to in this moment?
IncludesAllSendableFollowers(lstate, followers) ==
    \* all followers in this group have their cursor behind the head of the leader log
    /\ \A f \in followers : CanSendToFollower(lstate, f)
    \* there isn't a follower who could be sent to, but is not in this group
    /\ ~\E f \in Nodes :
        /\ f # lstate.id
        /\ f \notin followers
        /\ CanSendToFollower(lstate, f)

\* Get the next lowest entry above the current follow cursor position
\* specifically, choose an entry that is higher than the last pushed
\* such that there is not another entry that is also higher than the
\* last pushed but lower than the chosen entry. Only one entry can
\* match that criteria.                        
NextEntry(lstate, last_entry_id) ==
    CHOOSE e1 \in lstate.log :
        /\ IsHigherId(e1.entry_id, last_entry_id)
        /\ ~\E e2 \in lstate.log :
            /\ IsLowerId(e2.entry_id, e1.entry_id)
            /\ IsHigherId(e2.entry_id, last_entry_id)
            
GetAddEntryRequest(lstate, next_entries, follower) ==
    [type         |-> ADD_ENTRY_REQUEST,
     dest_node    |-> follower,
     source_node  |-> lstate.id,
     entry        |-> next_entries[follower],
     commit_index |-> lstate.commit_index,
     epoch        |-> lstate.epoch]
     
GetNextAddEntryRequests(lstate, next_entries, followers) ==
    { GetAddEntryRequest(lstate, next_entries, f) : f \in followers }
    
GetNextEntries(lstate, followers) ==
    [f \in followers |-> NextEntry(lstate, lstate.follow_cursor[f].last_pushed)]

LeaderSendsEntriesToFollowers ==
    \* enabling conditions
    \E leader \in Nodes, followers \in SUBSET Nodes :
        /\ followers # {}
        /\ LET lstate == node_state[leader]
           IN
            /\ lstate.status = LEADER
            /\ IncludesAllSendableFollowers(lstate, followers)
            \* state changes
            /\ LET next_entries == GetNextEntries(lstate, followers)
               IN /\ node_state' = [node_state EXCEPT ![leader].follow_cursor =
                                        [n \in Nodes |-> 
                                            IF n \in followers
                                            THEN [lstate.follow_cursor[n] EXCEPT !.last_pushed = next_entries[n].entry_id]
                                            ELSE lstate.follow_cursor[n]]]
                  /\ SendMessages(GetNextAddEntryRequests(lstate, next_entries, followers))
                  /\ UNCHANGED << metadata, metadata_version, operator_state, metadata, confirmed, operator_stop_ctr >>

(*---------------------------------------------------------
  A follower node confirms an entry to the leader
  
  The follower adds the entry to its log, sets the head index
  and updates its commit index with the commit index of 
  the request.
----------------------------------------------------------*)

GetAddEntryOkResponse(msg, fstate, entry) ==
    [type        |-> ADD_ENTRY_RESPONSE,
     dest_node   |-> msg.source_node,
     source_node |-> fstate.id,
     code        |-> OK,
     entry_id    |-> entry.entry_id,
     epoch       |-> fstate.epoch]
     
FollowerConfirmsEntry ==    
    \* enabling conditions
    \E msg \in DOMAIN messages :
        /\ IsEarliestReceivableEntryMessage(messages, msg, ADD_ENTRY_REQUEST)
        /\ LET f      == msg.dest_node
               fstate == node_state[f]
           IN
                /\ fstate.status \in {FOLLOWER, FENCED}
                /\ fstate.epoch <= msg.epoch \* reconfig could mean leader has higher epoch than follower
                \* state changes
                /\ node_state' = [node_state EXCEPT ![f].status       = FOLLOWER,
                                                    ![f].epoch        = msg.epoch,
                                                    ![f].leader       = msg.source_node,
                                                    ![f].log          = @ \union { msg.entry },
                                                    ![f].head_index   = msg.entry.entry_id,
                                                    ![f].commit_index = msg.commit_index]
                
                /\ ProcessedOneAndSendAnother(msg, GetAddEntryOkResponse(msg, fstate, msg.entry))
                /\ UNCHANGED << metadata, metadata_version, operator_state, metadata, confirmed, operator_stop_ctr >>


(*---------------------------------------------------------
  A follower node rejects an entry from the leader.
  
  
  If the leader has a lower epoch than the follower then the 
  follower must reject it with an INVALID_EPOCH response.
  
  Key points:
  - The epoch of the response should be the epoch of the
    request so that the leader will not ignore the response.
----------------------------------------------------------*)

GetAddEntryInvalidEpochResponse(nstate, msg) ==
    [type        |-> ADD_ENTRY_RESPONSE,
     dest_node   |-> msg.source_node,
     source_node |-> nstate.id,
     code        |-> INVALID_EPOCH,
     entry_id    |-> msg.entry.entry_id,
     epoch       |-> msg.epoch]

FollowerRejectsEntry ==    
    \* enabling conditions
    \E msg \in DOMAIN messages :
        /\ IsEarliestReceivableEntryMessage(messages, msg, ADD_ENTRY_REQUEST)
        /\ LET nstate == node_state[msg.dest_node]
           IN
                /\ nstate.epoch > msg.epoch
                \* state changes
                /\ ProcessedOneAndSendAnother(msg, GetAddEntryInvalidEpochResponse(nstate, msg))
                /\ UNCHANGED << metadata, metadata_version, operator_state, metadata, node_state, confirmed, operator_stop_ctr >>
                
(*---------------------------------------------------------
  A leader node handles an add entry response
  
  The leader updates the follow cursor last_confirmed
  entry id, it also may advance the commit index.
  
  An entry is committed when all of the following
  has occurred:
  - it has reached majority quorum
  - the entire log prefix has reached majority quorum
  - the entry epoch matches the current epoch

  Key points:  
  - Entries of prior epochs cannot be committed directly by
    themselves, only entries of the current epoch can be
    committed. Committing an entry of the current epoch
    also implicitly includes all prior entries.
    To find a counterexample where loss of confirmed writes
    occurs when committing entries of prior epochs directly,
    comment out the condition 'entry_id.epoch = nstate.epoch'
    below. Also see the Raft paper.

----------------------------------------------------------*)
GetEntry(entry_id, nstate) ==
    CHOOSE entry \in nstate.log : 
        CompareLogEntries(entry.entry_id, entry_id) = 0 

\* note that >= RF/2 instead of RF/2 + 1. This is because the 
\* leader is counting follow cursors only. It already has the
\* entry and is the + 1.
EntryReachedQuorum(entry_id, follow_cursor, rep_factor) ==
    Cardinality({ n \in Nodes :
                    /\ follow_cursor[n].status = ATTACHED 
                    /\ IsLowerOrEqualId(entry_id, follow_cursor[n].last_confirmed) }) 
                >= (rep_factor \div 2)

LogPrefixAtQuorum(nstate, entry_id, follow_cursor, rep_factor) ==
    \A entry \in nstate.log :
        \/ IsHigherId(entry.entry_id, entry_id)
        \/ /\ IsLowerOrEqualId(entry.entry_id, entry_id)
           /\ EntryReachedQuorum(entry.entry_id, follow_cursor, rep_factor)

EntryIsCommitted(nstate, entry_id, cursor, rep_factor) ==
    /\ LogPrefixAtQuorum(nstate, entry_id, cursor, rep_factor)
    /\ entry_id.epoch = nstate.epoch \* can only commit entries of the current epoch
        
LeaderHandlesEntryConfirm ==
    \* enabling conditions
    \E msg \in DOMAIN messages :
        /\ IsEarliestReceivableEntryMessage(messages, msg, ADD_ENTRY_RESPONSE)
        /\ LET leader   == msg.dest_node
               follower == msg.source_node
               nstate   == node_state[leader]
           IN
                /\ nstate.status = LEADER
                /\ nstate.epoch = msg.epoch
                /\ msg.code = OK
                /\ nstate.follow_cursor[follower].status = ATTACHED
                \* state changes
                /\ LET updated_cursor == [nstate.follow_cursor EXCEPT ![follower].last_confirmed = msg.entry_id]
                       entry          == GetEntry(msg.entry_id, nstate)
                   IN
                      /\ IF EntryIsCommitted(nstate, msg.entry_id, updated_cursor, nstate.rep_factor)
                         THEN /\ node_state' = [node_state EXCEPT ![leader].follow_cursor = updated_cursor,
                                                                  ![leader].commit_index  = IF IsHigherId(msg.entry_id, @)
                                                                                            THEN msg.entry_id
                                                                                            ELSE @]
                              /\ confirmed' = [confirmed EXCEPT ![entry.value] = TRUE] 
                         ELSE /\ node_state' = [node_state EXCEPT ![leader].follow_cursor = updated_cursor]
                              /\ UNCHANGED confirmed
                      /\ MessageProcessed(msg)
            /\ UNCHANGED << metadata, metadata_version, operator_state, metadata, operator_stop_ctr >>
            
(*---------------------------------------------------------
  A leader node handles an add entry rejection response
  
  On receiving an INVALID_EPOCH response the leader knows
  it is stale and it abdicates by fencing itself.
----------------------------------------------------------*)
LeaderHandlesEntryRejection ==
    \* enabling conditions
    \E msg \in DOMAIN messages :
        /\ IsEarliestReceivableEntryMessage(messages, msg, ADD_ENTRY_RESPONSE)
        /\ LET nstate == node_state[msg.dest_node]
           IN
                /\ nstate.status = LEADER
                /\ nstate.epoch = msg.epoch
                /\ msg.code = INVALID_EPOCH
                \* Actions
                /\ node_state' = [node_state EXCEPT ![msg.dest_node].status        = FENCED,
                                                    ![msg.dest_node].follow_cursor = [n1 \in Nodes |-> NoCursor]]
                /\ MessageProcessed(msg)
                /\ UNCHANGED << metadata, metadata_version, operator_state, metadata, confirmed, operator_stop_ctr >>            


(*---------------------------------------------------------
  The operator starts a node swap reconfiguration
  
  Reconfiguration is the process of changing the shard
  ensemble safely through a controlled process. 
  A node swap operation is the removing of one follower
  and replacing it with another.
  
  Reconfiguration can only be performed when:
  - there is an elected leader
  - there is no active leader election in-progress
  - there is no active reconfiguration in-progress
  
  A node swap reconfiguration is performed via a 2-phase commit:
  - PREPARE phase: 1) Operator updates the metadata with the reconfiguration
                      details of: old node, new node, PREPARE phase.
                   2) Leader fences the old node. This deactivates
                      the follow cursor in the leader for the 
                      old node. Sends back a snapshot to the operator.
                   3) Operator sends the snapshot to the new node.
  - COMMIT phase:  1) Operator update the phase in the reconfig metadata 
                      to COMMIT.
                   2) Send a commit request to the leader. 
                   3) Leader removes the follow cursor for the old node 
                      completely and activates a follow cursor for the 
                      new node and confirms to the operator.
                   4) The operator updates the metadata to clear the
                      reconfiguration op state.
                   
  Key points:
  - a reconfiguration op increments the epoch
  - a node swap cannot swap out the leader
----------------------------------------------------------*)

ReconfigurationAllowed(ostate) ==
   /\ ostate.status = RUNNING
   /\ ostate.md.shard_status = STEADY_STATE
   /\ ostate.md.reconfig = NIL
   /\ ostate.md_version = metadata_version

GetPrepareNodeSwapReconfigRequest(ostate, old_node, new_epoch) ==
    [type        |-> PREPARE_RECONFIG_REQUEST,
     op          |-> NODE_SWAP,
     epoch       |-> new_epoch,
     node        |-> ostate.md.leader,
     operator    |-> ostate.id,
     old_node    |-> old_node]

OperatorStartsNodeSwapReconfiguration ==
    \* enabling conditions
    /\ metadata.epoch < MaxEpochs \* state space reduction
    /\ \E o \in Operators :
        LET ostate == operator_state[o]
        IN /\ ReconfigurationAllowed(ostate)
           /\ \E old_node, new_node \in Nodes :
                /\ old_node \in ostate.md.ensemble
                /\ old_node # ostate.md.leader
                /\ new_node \notin ostate.md.ensemble
                /\ LET new_md_version == metadata_version + 1
                       new_epoch      == metadata.epoch + 1
                       reconfig       == [phase               |-> PREPARE,
                                          op                  |-> NODE_SWAP,
                                          rep_factor          |-> ostate.md.rep_factor,
                                          old_node            |-> old_node,
                                          new_node            |-> new_node,
                                          epoch               |-> new_epoch,
                                          new_node_head_index |-> NoEntryId]
                       new_md         == [ostate.md EXCEPT !.shard_status = RECONFIGURATION,
                                                           !.epoch        = new_epoch,
                                                           !.reconfig     = reconfig]
                   IN
                      \* state changes
                      /\ metadata_version' = new_md_version
                      /\ metadata' = new_md
                      /\ operator_state' = [operator_state EXCEPT ![o].md_version = new_md_version,
                                                                  ![o].md         = new_md]
                      /\ SendMessage(GetPrepareNodeSwapReconfigRequest(ostate, old_node, new_epoch))
                      /\ UNCHANGED << node_state, confirmed, operator_stop_ctr >>


(*---------------------------------------------------------
  The operator starts an expand reconfiguration
  
  The operator selects a new node to add to the shard
  ensemble in order to increase the replication
  factor.
  
  See the Node Swap reconfiguration for more details. All
  applies except that there is no old node, only a new
  node. The PREPARE phase only involves the obtaining
  of the snapshot.
----------------------------------------------------------*)

GetPrepareExpandReconfigRequest(ostate, new_epoch) ==
    [type        |-> PREPARE_RECONFIG_REQUEST,
     op          |-> EXPAND,
     epoch       |-> new_epoch,
     node        |-> ostate.md.leader,
     operator    |-> ostate.id]

OperatorStartsExpandReconfiguration ==
    \* enabling conditions
    /\ metadata.epoch < MaxEpochs \* state space reduction
    /\ \E o \in Operators :
        LET ostate == operator_state[o]
        IN /\ ReconfigurationAllowed(ostate)
           /\ \E new_node \in Nodes :
                /\ new_node \notin ostate.md.ensemble
                /\ LET new_md_version == metadata_version + 1
                       new_epoch      == metadata.epoch + 1
                       reconfig       == [phase               |-> PREPARE,
                                          op                  |-> EXPAND,
                                          rep_factor          |-> ostate.md.rep_factor + 1,
                                          new_node            |-> new_node,
                                          epoch               |-> new_epoch,
                                          new_node_head_index |-> NoEntryId]
                       new_md         == [ostate.md EXCEPT !.shard_status = RECONFIGURATION,
                                                           !.epoch        = new_epoch,
                                                           !.reconfig     = reconfig]
                   IN
                      \* state changes
                      /\ metadata_version' = new_md_version
                      /\ metadata' = new_md
                      /\ operator_state' = [operator_state EXCEPT ![o].md_version = new_md_version,
                                                                  ![o].md         = new_md]
                      /\ SendMessage(GetPrepareExpandReconfigRequest(ostate, new_epoch))
                      /\ UNCHANGED << node_state, confirmed, operator_stop_ctr >>
                      
(*---------------------------------------------------------
  The operator starts a contract reconfiguration
  
  This operation reduces the replication factor by removing
  a node from the ensemble safely.
  
  A node cannot be removed safely if by removing it the leader's
  commit index would be recalculated as a lower index. This
  would leave previously committed entries as uncommitted and is
  not safe.
  
  A contract reconfiguration is performed via a 2-phase commit although
  it strictly does not require two phases for correctness. The reason
  to use a two-phase commit is that we can fence off the node we want
  to remove during the prepare phase and then wait for the commit index
  in the leader to pass the head index of the node to be removed. At
  that point the commit phase will succeed.
  
  - PREPARE phase: 1) Operator updates the metadata with the reconfiguration
                      details of: old node, PREPARE phase.
                   2) Leader fences the old node. This deactivates
                      the follow cursor in the leader for the 
                      old node.
  - COMMIT phase:  1) Operator updates the phase in the reconfig metadata 
                      to COMMIT.
                   2) Send a commit request to the leader. 
                   3) Leader removes the follow cursor for the old node 
                      completely, only if the commit index is not affected.
                      Confirms to the operator if it was successful or not.
                   4) The operator updates the metadata to clear the
                      reconfiguration op state upon success.
                      
Key points:
 - The operator can attempt the commit phase repeatedly
   until the leader responds with success.
----------------------------------------------------------*)

GetPrepareContractReconfigRequest(ostate, old_node, new_epoch) ==
    [type        |-> PREPARE_RECONFIG_REQUEST,
     op          |-> CONTRACT,
     epoch       |-> new_epoch,
     node        |-> ostate.md.leader,
     operator    |-> ostate.id,
     old_node    |-> old_node]

OperatorStartsContractReconfiguration ==
    \* enabling conditions
    /\ metadata.epoch < MaxEpochs \* state space reduction
    /\ \E o \in Operators :
        LET ostate == operator_state[o]
        IN /\ ReconfigurationAllowed(ostate)
           /\ ostate.md.rep_factor > 3
           /\ \E old_node \in Nodes :
                /\ old_node \in ostate.md.ensemble
                /\ old_node # ostate.md.leader
                /\ LET new_md_version == metadata_version + 1
                       new_epoch      == metadata.epoch + 1
                       reconfig       == [phase               |-> PREPARE,
                                          op                  |-> CONTRACT,
                                          rep_factor          |-> ostate.md.rep_factor - 1,
                                          old_node            |-> old_node,
                                          epoch               |-> new_epoch]
                       new_md         == [ostate.md EXCEPT !.shard_status = RECONFIGURATION,
                                                           !.epoch        = new_epoch,
                                                           !.reconfig     = reconfig]
                   IN
                      \* state changes
                      /\ metadata_version' = new_md_version
                      /\ metadata' = new_md
                      /\ operator_state' = [operator_state EXCEPT ![o].md_version = new_md_version,
                                                                  ![o].md         = new_md]
                      /\ SendMessage(GetPrepareContractReconfigRequest(ostate, old_node, new_epoch))
                      /\ UNCHANGED << node_state, confirmed, operator_stop_ctr >>                      

(*---------------------------------------------------------
  The leader handles a reconfiguration request
  
  This action covers all types of reconfiguration.
  
  NODE_SWAP and CONTRACT:
  - change the old node follow cursor to PENDING_REMOVAL
    which deactivates it.
    
  Updates the epoch of the leader to the new epoch.
----------------------------------------------------------*)

GetPrepareReconfigResponse(msg, nstate) ==
    IF msg.op = CONTRACT
    THEN [type         |-> PREPARE_RECONFIG_RESPONSE,
          op           |-> msg.op,
          operator     |-> msg.operator,
          node         |-> nstate.id,
          epoch        |-> msg.epoch]
    ELSE [type         |-> PREPARE_RECONFIG_RESPONSE,
          op           |-> msg.op,
          operator     |-> msg.operator,
          node         |-> nstate.id,
          epoch        |-> msg.epoch,
          snapshot     |-> nstate.log,
          head_index   |-> nstate.head_index,
          commit_index |-> nstate.commit_index]

LeaderHandlesPrepareReconfigRequest ==
    \* enabling conditions
    \E msg \in DOMAIN messages :
        /\ ReceivableMessageOfType(messages, msg, PREPARE_RECONFIG_REQUEST)
        /\ LET nstate == node_state[msg.node]
           IN /\ nstate.epoch < msg.epoch
              /\ nstate.status = LEADER
              /\ nstate.reconfig_inprog = FALSE
              \* Actions
              /\ IF msg.op = EXPAND 
                 THEN node_state' = [node_state EXCEPT ![nstate.id].epoch           = msg.epoch,
                                                       ![nstate.id].reconfig_inprog = TRUE]
                 \* NODE_SWAP or CONTRACT
                 ELSE node_state' = [node_state EXCEPT ![nstate.id].epoch           = msg.epoch,
                                                       ![nstate.id].reconfig_inprog = TRUE,
                                                       ![nstate.id].follow_cursor[msg.old_node].status = PENDING_REMOVAL]
              /\ ProcessedOneAndSendAnother(msg, GetPrepareReconfigResponse(msg, nstate))
              /\ UNCHANGED << metadata_version, metadata, operator_state, confirmed, operator_stop_ctr >>


(*---------------------------------------------------------
  Operator handles Prepare Reconfig response
  
  NODE_SWAP and EXPAND:
  - Receives a snapshot from the leader and sends a snapshot
    request to the new node.
    
  CONTRACT
  - Send a commit request to the leader
----------------------------------------------------------*)

GetCommitContractReconfigRequest(ostate) ==
    [type        |-> COMMIT_RECONFIG_REQUEST,
     op          |-> CONTRACT,
     rep_factor  |-> ostate.md.reconfig.rep_factor,
     epoch       |-> ostate.md.epoch,
     node        |-> ostate.md.leader,
     operator    |-> ostate.id,
     old_node    |-> ostate.md.reconfig.old_node]

GetSnapshotRequest(ostate, snapshot, head_index, commit_index) ==
    [type         |-> SNAPSHOT_REQUEST,
     node         |-> ostate.md.reconfig.new_node,
     operator     |-> ostate.id,
     epoch        |-> ostate.md.epoch,
     snapshot     |-> snapshot,
     head_index   |-> head_index,
     commit_index |-> commit_index]

OperatorHandlesPrepareReconfigResponse ==
    \* enabling conditions
    \E o \in Operators :
        LET ostate == operator_state[o]
        IN
            /\ ostate.status = RUNNING
            /\ ostate.md.shard_status = RECONFIGURATION 
            /\ ostate.md.reconfig.phase = PREPARE
            /\ ostate.md_version = metadata_version
            /\ \E msg \in DOMAIN messages :
                /\ ReceivableMessageOfType(messages, msg, PREPARE_RECONFIG_RESPONSE)
                /\ msg.operator = o
                /\ ostate.md.epoch = msg.epoch
                \* state changes
                /\ IF msg.op \in {NODE_SWAP, EXPAND}
                   THEN /\ ProcessedOneAndSendAnother(msg, GetSnapshotRequest(ostate,
                                                                              msg.snapshot,
                                                                              msg.head_index,
                                                                              msg.commit_index))
                        /\ UNCHANGED << metadata_version, metadata, operator_state, 
                                        node_state, confirmed, operator_stop_ctr >>
                   ELSE \* CONTRACT
                        LET new_md == [ostate.md EXCEPT !.reconfig.phase = COMMIT]
                        IN /\ metadata_version' = metadata_version + 1
                           /\ metadata' = new_md
                           /\ operator_state' = [operator_state EXCEPT ![o].md_version = metadata_version + 1,
                                                                       ![o].md         = new_md] 
                           /\ ProcessedOneAndSendAnother(msg, GetCommitContractReconfigRequest(ostate))
                           /\ UNCHANGED << node_state, confirmed, operator_stop_ctr >>

(*---------------------------------------------------------
  The new follower handles a snapshot request
  
  A follower updates its log, head and commit index. Sets
  itself to FENCED while it waits for replication from
  the leader.
----------------------------------------------------------*)

GetSnapshotResponse(msg) ==
    [type         |-> SNAPSHOT_RESPONSE,
     operator     |-> msg.operator,
     node         |-> msg.node,
     epoch        |-> msg.epoch,
     head_index   |-> msg.head_index]

NodeHandlesSnapshotRequest ==
    \* enabling conditions
    \E msg \in DOMAIN messages :
        /\ ReceivableMessageOfType(messages, msg, SNAPSHOT_REQUEST)
        /\ LET nstate == node_state[msg.node]
           IN /\ nstate.epoch < msg.epoch
              \* state changes
              /\ node_state' = [node_state EXCEPT ![nstate.id] =
                                    [@ EXCEPT !.status         = FENCED,
                                              !.epoch          = msg.epoch,
                                              !.follow_cursor  = [n \in Nodes |-> NoCursor],
                                              !.log            = msg.snapshot,
                                              !.head_index     = msg.head_index,
                                              !.commit_index   = msg.commit_index]] 
              /\ ProcessedOneAndSendAnother(msg, GetSnapshotResponse(msg))
              /\ UNCHANGED << metadata_version, metadata, operator_state, confirmed, operator_stop_ctr >>

(*---------------------------------------------------------
  Operator handles Snapshop response
  
  Operator sends a commit reconfig request to the leader.
----------------------------------------------------------*)

GetCommitReconfigRequest(ostate, new_node_head_index) ==
    IF ostate.md.reconfig.op = NODE_SWAP
    THEN
        [type       |-> COMMIT_RECONFIG_REQUEST,
         op         |-> NODE_SWAP,
         rep_factor |-> ostate.md.reconfig.rep_factor,
         node       |-> ostate.md.leader,
         operator   |-> ostate.id,
         epoch      |-> ostate.md.epoch,
         old_node   |-> ostate.md.reconfig.old_node,
         new_node   |-> ostate.md.reconfig.new_node,
         head_index |-> new_node_head_index]
    ELSE
        [type       |-> COMMIT_RECONFIG_REQUEST,
         op         |-> EXPAND,
         rep_factor |-> ostate.md.reconfig.rep_factor,
         node       |-> ostate.md.leader,
         operator   |-> ostate.id,
         epoch      |-> ostate.md.epoch,
         new_node   |-> ostate.md.reconfig.new_node,
         head_index |-> new_node_head_index]

OperatorHandlesSnapshotResponse ==
    \* enabling conditions
    \E o \in Operators :
        LET ostate == operator_state[o]
        IN
            /\ ostate.status = RUNNING
            /\ ostate.md.shard_status = RECONFIGURATION
            /\ ostate.md.reconfig.phase = PREPARE 
            /\ metadata_version = ostate.md_version
            /\ \E msg \in DOMAIN messages :
                /\ ReceivableMessageOfType(messages, msg, SNAPSHOT_RESPONSE)
                /\ msg.operator = o
                /\ ostate.md.epoch = msg.epoch
                \* state changes
                /\ LET new_md == [ostate.md EXCEPT !.reconfig.phase               = COMMIT,
                                                   !.reconfig.new_node_head_index = msg.head_index]
                   IN /\ metadata_version' = metadata_version + 1
                      /\ metadata' = new_md
                      /\ operator_state' = [operator_state EXCEPT ![o].md_version = metadata_version + 1,
                                                                  ![o].md         = new_md]
                      /\ ProcessedOneAndSendAnother(msg, GetCommitReconfigRequest(ostate, msg.head_index))
            /\ UNCHANGED << node_state, confirmed, operator_stop_ctr >>


(*---------------------------------------------------------
  The leader handles a NODE_SWAP Commit Reconfig request
  
  The leader removes the cursor of the old node and
  activates a cursor for the new node, to match its
  head index.
  
  This may advance the commit index.
----------------------------------------------------------*)

NewCommitIndex(nstate, updated_cursor, rep_factor) ==
    IF \E entry \in nstate.log : EntryIsCommitted(nstate, entry.entry_id, updated_cursor, rep_factor)
    THEN
        LET max_entry == CHOOSE entry \in nstate.log :
                            /\ EntryIsCommitted(nstate, entry.entry_id, updated_cursor, rep_factor)
                            /\ ~\E e1 \in nstate.log :
                                /\ IsHigherId(e1.entry_id, entry.entry_id)
                                /\ EntryIsCommitted(nstate, e1.entry_id, updated_cursor, rep_factor)
        IN max_entry.entry_id
    ELSE NoEntryId

UpdateConfirmed(nstate, commit_index) ==
    [v \in DOMAIN confirmed |-> IF confirmed[v] = TRUE
                                THEN TRUE
                                ELSE IF \E entry \in nstate.log : 
                                            /\ IsLowerOrEqualId(entry.entry_id, commit_index)
                                            /\ entry.value = v
                                     THEN TRUE
                                     ELSE FALSE]

GetCommitNodeSwapReconfigResponse(msg) ==
    [type     |-> COMMIT_RECONFIG_RESPONSE,
     op       |-> NODE_SWAP,
     operator |-> msg.operator,
     node     |-> msg.node,
     epoch    |-> msg.epoch,
     old_node |-> msg.old_node,
     new_node |-> msg.new_node]

LeaderHandlesCommitNodeSwapReconfigRequest ==
    \* enabling conditions
    \E msg \in DOMAIN messages :
        /\ ReceivableMessageOfType(messages, msg, COMMIT_RECONFIG_REQUEST)
        /\ LET nstate == node_state[msg.node]
           IN /\ nstate.epoch = msg.epoch
              /\ nstate.status = LEADER
              /\ msg.op = NODE_SWAP 
              /\ nstate.reconfig_inprog = TRUE
              /\ nstate.follow_cursor[msg.old_node].status = PENDING_REMOVAL
              /\ nstate.follow_cursor[msg.new_node].status = NIL
              \* state changes
              /\ LET updated_cursor   == [n \in Nodes |->
                                            IF n = msg.old_node
                                            THEN NoCursor
                                            ELSE IF n = msg.new_node
                                                 THEN [status         |-> ATTACHED,
                                                       last_pushed    |-> msg.head_index,
                                                       last_confirmed |-> msg.head_index]
                                                 ELSE nstate.follow_cursor[n]]
                     new_commit_index == NewCommitIndex(nstate, updated_cursor, msg.rep_factor)
                 IN
                      /\ node_state' = [node_state EXCEPT ![nstate.id].follow_cursor   = updated_cursor,
                                                          ![nstate.id].commit_index    = new_commit_index,
                                                          ![nstate.id].reconfig_inprog = FALSE] 
                      /\ confirmed' = UpdateConfirmed(nstate, new_commit_index)
                      /\ ProcessedOneAndSendAnother(msg, GetCommitNodeSwapReconfigResponse(msg))
                      /\ UNCHANGED << metadata_version, metadata, operator_state, operator_stop_ctr >>

(*---------------------------------------------------------
  The leader handles an EXPAND Commit Reconfig request
  
  The leader activates a cursor for the new node, to match its
  head index.
  
  This may advance the commit index.
----------------------------------------------------------*)

GetCommitExpandReconfigResponse(msg) ==
    [type     |-> COMMIT_RECONFIG_RESPONSE,
     op       |-> EXPAND,
     operator |-> msg.operator,
     node     |-> msg.node,
     epoch    |-> msg.epoch,
     new_node |-> msg.new_node]

LeaderHandlesCommitExpandReconfigRequest ==
    \* enabling conditions
    \E msg \in DOMAIN messages :
        /\ ReceivableMessageOfType(messages, msg, COMMIT_RECONFIG_REQUEST)
        /\ LET nstate == node_state[msg.node]
           IN /\ nstate.epoch = msg.epoch
              /\ nstate.status = LEADER
              /\ nstate.reconfig_inprog = TRUE
              /\ msg.op = EXPAND 
              /\ nstate.follow_cursor[msg.new_node].status = NIL
              \* state changes
              /\ LET updated_cursor   == [n \in Nodes |->
                                            IF n = msg.new_node
                                            THEN [status         |-> ATTACHED,
                                                  last_pushed    |-> msg.head_index,
                                                  last_confirmed |-> msg.head_index]
                                            ELSE nstate.follow_cursor[n]]
                     new_commit_index == NewCommitIndex(nstate, updated_cursor, msg.rep_factor)
                 IN
                      /\ node_state' = [node_state EXCEPT ![nstate.id].rep_factor      = msg.rep_factor,
                                                          ![nstate.id].follow_cursor   = updated_cursor,
                                                          ![nstate.id].commit_index    = new_commit_index,
                                                          ![nstate.id].reconfig_inprog = FALSE] 
                      /\ confirmed' = UpdateConfirmed(nstate, new_commit_index)
                      /\ ProcessedOneAndSendAnother(msg, GetCommitExpandReconfigResponse(msg))
                      /\ UNCHANGED << metadata_version, metadata, operator_state, operator_stop_ctr >>

(*---------------------------------------------------------
  The leader handles a CONTRACT Commit Reconfig request
  
  The leader checks that the commit index is unaffected
  by the removal of the old node and if so removes its
  cursor.
  
  This does not affect the commit index.
  
  Key points:
  - The leader would need to respond with an "unsafe"
    return code if the commit index would have been
    affected. That way the operator could periodically
    retry the commit until a success reponse
    is received. In this spec we simply model that
    the commit only succeeds if the commit index is
    unaffected. Because the message passing doesn't
    lose messages, this implicitly models these retries. 
  
  - It would be possible to include a "force" flag to
    force a leader to remove a node despite it being
    unsafe.
----------------------------------------------------------*)

GetCommitContractReconfigResponse(msg) ==
    [type       |-> COMMIT_RECONFIG_RESPONSE,
     op         |-> CONTRACT,
     operator   |-> msg.operator,
     node       |-> msg.node,
     epoch      |-> msg.epoch,
     old_node   |-> msg.old_node]

LeaderHandlesCommitContractReconfigRequest ==
    \* enabling conditions
    \E msg \in DOMAIN messages :
        /\ ReceivableMessageOfType(messages, msg, COMMIT_RECONFIG_REQUEST)
        /\ LET nstate == node_state[msg.node]
           IN /\ nstate.epoch = msg.epoch
              /\ nstate.status = LEADER
              /\ nstate.reconfig_inprog = TRUE
              /\ msg.op = CONTRACT 
              /\ nstate.follow_cursor[msg.old_node].status = PENDING_REMOVAL
              /\ LET updated_cursor   == [n \in Nodes |->
                                            IF n = msg.old_node
                                            THEN NoCursor
                                            ELSE nstate.follow_cursor[n]]
                     new_commit_index == NewCommitIndex(nstate, updated_cursor, msg.rep_factor)
                 IN
                      /\ IsSameId(new_commit_index, nstate.commit_index)
                      \* state changes
                      /\ node_state' = [node_state EXCEPT ![nstate.id].rep_factor      = msg.rep_factor,
                                                          ![nstate.id].follow_cursor   = updated_cursor,
                                                          ![nstate.id].reconfig_inprog = FALSE] 
                      /\ ProcessedOneAndSendAnother(msg, GetCommitContractReconfigResponse(msg))
                      /\ UNCHANGED << metadata_version, metadata, operator_state, confirmed, operator_stop_ctr >>

(*---------------------------------------------------------
  Operator completes reconfiguration
  
  The operator updates the shard ensemble according
  to the type of reconfiguration and updates the
  metadata.
----------------------------------------------------------*)

NewEnsemble(md, msg) ==
    CASE msg.op = NODE_SWAP ->
            (md.ensemble \ {msg.old_node}) \union {msg.new_node}
      [] msg.op = EXPAND ->
            md.ensemble \union {msg.new_node}
      [] msg.op = CONTRACT ->
            md.ensemble \ {msg.old_node}

OperatorCompletesReconfiguration ==
    \* enabling conditions
    \E o \in Operators :
        LET ostate == operator_state[o]
        IN /\ ostate.status = RUNNING
           /\ \E msg \in DOMAIN messages :
                /\ ReceivableMessageOfType(messages, msg, COMMIT_RECONFIG_RESPONSE)
                /\ msg.operator = o
                /\ ostate.md.epoch = msg.epoch
                /\ ostate.md.shard_status = RECONFIGURATION
                /\ ostate.md.reconfig.phase = COMMIT
                \* state changes
                /\ LET new_ensemble == NewEnsemble(ostate.md, msg)
                       new_md       == [ostate.md EXCEPT !.shard_status = STEADY_STATE,
                                                         !.ensemble     = new_ensemble,
                                                         !.rep_factor   = ostate.md.reconfig.rep_factor,
                                                         !.reconfig     = NIL]
                   IN 
                      /\ metadata_version' = metadata_version + 1
                      /\ metadata' = new_md
                      /\ operator_state' = [operator_state EXCEPT ![o].md_version = metadata_version + 1,
                                                                  ![o].md         = new_md]
                      /\ MessageProcessed(msg)
                      /\ UNCHANGED << node_state, confirmed, operator_stop_ctr >>

(*---------------------------------------------------------
  Next state formula
----------------------------------------------------------*)        
Next ==
    \* Election
    \/ OperatorStarts                             \* an operator starts and loads the metadata
    \/ OperatorStops                              \* a running operator stops, losing all local state
    \/ OperatorStartsElection                     \* election starts, fencing requests sent
    \/ NodeHandlesFencingRequest                  \* node fences itself, responds with head index
    \/ OperatorHandlesPreQuorumFencingResponse    \* operator handles fence response, not reached quorum yet
    \/ OperatorHandlesQuorumFencingResponse       \* operator handles fence response, reaching quorum, choosing leader
    \/ NodeHandlesBecomeLeaderRequest             \* new leader receives notification of leadership
    \/ OperatorHandlesBecomeLeaderResponse        \* operator handles new leader confirmation
    \/ NodeHandlesTruncateRequest                 \* follower truncates it log to safe point
    \/ LeaderHandlesTruncateResponse              \* leader receives truncation response
    \/ OperatorHandlesPostQuorumFencingResponse   \* operator handles fence response after leader elected, adds as a follower
    \/ LeaderHandlesAddFollowerRequest            \* leader notified of follower (post election)
    \* Writes and replication
    \/ Write                                      \* a client writes an entry to the leader
    \/ LeaderSendsEntriesToFollowers              \* leader sends entries to followers via cursors
    \/ FollowerConfirmsEntry                      \* follower receives an entry, confirms to leader
    \/ FollowerRejectsEntry                       \* follower receives an entry with a stale epoch, sends INVALID_EPOCH to leader
    \/ LeaderHandlesEntryConfirm                  \* leader receives add confirm, confirms to client if reached majority
    \/ LeaderHandlesEntryRejection                \* leader receives add rejection, abdicates
    \* Reconfiguration
    \/ OperatorStartsNodeSwapReconfiguration      \* operator sends node swap reconfig request to leader
    \/ OperatorStartsExpandReconfiguration        \* operator sends expand reconfig request to leader
    \/ OperatorStartsContractReconfiguration      \* operator sends contract reconfig request to leader
    \/ LeaderHandlesPrepareReconfigRequest        \* leader handles prepare phase reconfig request
    \/ OperatorHandlesPrepareReconfigResponse     \* operator handles prepare phase reconfig response
    \/ NodeHandlesSnapshotRequest                 \* node receives a snapshot
    \/ OperatorHandlesSnapshotResponse            \* operator handles snapshot confirmation from node
    \/ LeaderHandlesCommitNodeSwapReconfigRequest \* leader commits node swap reconfig
    \/ LeaderHandlesCommitExpandReconfigRequest   \* leader commits expand reconfig
    \/ LeaderHandlesCommitContractReconfigRequest \* leader commits contract reconfig
    \/ OperatorCompletesReconfiguration           \* operator completes reconfiguration
    
(*-------------------------------------------------    
    INVARIANTS
--------------------------------------------------*)

AreEqual(entry1, entry2) ==
    /\ entry1.entry_id.epoch = entry2.entry_id.epoch
    /\ entry1.entry_id.offset = entry2.entry_id.offset
    /\ entry1.value = entry2.value


\* The log on all nodes matches at and below the commit index         
NoLogDivergence ==
    IF metadata.leader # NIL
    THEN \A n \in metadata.ensemble :
        \* all entries at or below commit index contain the same value
        \* for the given index across all nodes that have it
        /\ \A entry \in node_state[metadata.leader].log :
            IF IsLowerOrEqualId(entry.entry_id, node_state[n].commit_index)
            THEN ~\E copy \in node_state[n].log :
                    /\ IsSameId(entry.entry_id, copy.entry_id)
                    /\ ~AreEqual(entry, copy)
            ELSE TRUE        
        \* all entries in the node log exists in the leader log
        /\ \A entry \in node_state[n].log :
            IF IsLowerOrEqualId(entry.entry_id, node_state[n].commit_index)
            THEN \E match \in node_state[metadata.leader].log :
                AreEqual(entry, match)
            ELSE TRUE
    ELSE TRUE

\* There cannot be a confirmed write that does not exist in the leader's log
NoLossOfConfirmedWrite ==
    IF metadata.leader # NIL /\ Cardinality(DOMAIN confirmed) > 0 
    THEN
        \A v \in DOMAIN confirmed :
            \/ /\ confirmed[v] = TRUE
               /\ \E entry \in node_state[metadata.leader].log : entry.value = v
            \/ confirmed[v] = FALSE
    ELSE TRUE

\* messages should not contain conflicting data
ValidMessages ==
    /\ ~\E msg \in DOMAIN messages :
        /\ msg.type = ADD_FOLLOWER_REQUEST
        /\ msg.follower = msg.node
    /\ ~\E msg \in DOMAIN messages :
        /\ msg.type \in { ADD_ENTRY_REQUEST, ADD_ENTRY_RESPONSE,
                          TRUNCATE_REQUEST, TRUNCATE_RESPONSE }
        /\ msg.dest_node = msg.source_node
    /\ ~\E msg \in DOMAIN messages :
        /\ msg.type = PREPARE_RECONFIG_REQUEST
        /\ msg.op = NODE_SWAP
        /\ msg.node = msg.old_node
    /\ ~\E msg \in DOMAIN messages :
        /\ msg.type = COMMIT_RECONFIG_REQUEST
        /\ msg.op \in {NODE_SWAP, EXPAND}
        /\ msg.node = msg.new_node
    /\ ~\E msg \in DOMAIN messages :
        /\ msg.type = PREPARE_RECONFIG_REQUEST
        /\ msg.op = CONTRACT
        /\ msg.node = msg.old_node

LegalLeaderAndEnsemble ==
    /\ IF metadata.leader # NIL
       THEN metadata.leader \in metadata.ensemble
       ELSE TRUE
    /\ \A o \in Operators :
        IF /\ operator_state[o].md # NIL
           /\ operator_state[o].md.leader # NIL
        THEN operator_state[o].md.leader \in operator_state[o].md.ensemble
        ELSE TRUE
    /\ metadata.rep_factor = Cardinality(metadata.ensemble)

(*-------------------------------------------------    
  LIVENESS
    
  Eventually:
  - all values will be committed.
  - reconfigutions will be completed
--------------------------------------------------*)
AllValuesCommitted ==
    \A v \in Values :
        /\ v \in DOMAIN confirmed
        /\ confirmed[v] = TRUE

EventuallyAllValuesCommitted ==
    []<>AllValuesCommitted

ReconfigurationStarted ==
    metadata.reconfig # NIL

ReconfigurationCompleted ==
    metadata.reconfig = NIL

EventuallyReconfigurationCompletes ==
    ReconfigurationStarted ~> ReconfigurationCompleted

LivenessSpec == Init /\ [][Next]_vars /\ WF_vars(Next)    

=============================================================================
\* Modification History
\* Last modified Mon Jan 24 18:03:33 CET 2022 by GUNMETAL
\* Last modified Mon Jan 24 15:25:04 CET 2022 by jvanlightly
\* Created Mon Dec 27 18:48:47 CET 2021 by jvanlightly