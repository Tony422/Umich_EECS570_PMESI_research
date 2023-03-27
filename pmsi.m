
-- PMSI protocol

----------------------------------------------------------------------
-- Constants
----------------------------------------------------------------------
const
  ProcCount: 3;          -- number processors
  ValueCount:   2;       -- number of data values.
  VC0: 0;                -- msg channel
  BufferSize: 3;   -- buffer size
  
  CoreReqBuffer_size: ProcCount; -- core request buffer
  CoreWBBuffer_size: ProcCount;  -- core write-back buffer
  PRLUT_size: ProcCount; --pending request lookup table

  which_fifo_type:Boolean; --true for PR, false for PWB

  QMax: 2;
  NumVCs: VC2 - VC0 + 1;
  NetMax: ProcCount+2;

  --MemAddress: 2;

----------------------------------------------------------------------
-- Types
----------------------------------------------------------------------
type
  Proc: scalarset(ProcCount);   -- unordered range of processors
  Value: scalarset(ValueCount); -- arbitrary values for tracking coherence
  --addrType: scalarset(MemAddress); --------2 cache line
  
  Home: enum { HomeType };      -- need enumeration for IsMember calls
  Node: union { Home , Proc };

  VCType: VC0..NumVCs-1;

  channelType: 0..ProcCount;

  Ackcount:(1-ProcCount)..ProcCount - 1 ;
  -- HeadPtr: 0...(ProcCount + ProcCount - 1);
  -- tailPtr: -1...(ProcCount + ProcCount - 1);

  fifo:
    Record
      buf: array [0..BufferSize-1] of Message;
      head: 0..BufferSize-1;
      tail: 0..BufferSize-1;
    end;

  MessageType: enum {  GetM,
                       GetS,
                       Upg,
                       PutM,
                       Data       
                    };

  Message:
    Record
      mtype: MessageType;
      src: Node;
      dest: Node;
      -- do not need a destination for verification; the destination is indicated by which array entry in the Net the message is placed
      --vc: VCType;
      val: Value;
      --addr: addrType;
    End;

  HomeState:
    Record
      state: enum { 
        H_IorS, 
        H_IorS_D,
        H_M,
        H_M_D
      }; 								--transient states during recall
     val: Value; 
     PRLUT: fifo;
     channel: channelType;
    End;

  ProcState:
    Record
      state: enum { 
            Proc_I,
            Proc_S,
            Proc_M,
            Proc_IS_D,
            Proc_IM_D,
            Proc_SM_W,
            Proc_MI_WB,
            Proc_MS_WB,
            Proc_IM_D_I,
            Proc_IS_D_I,
            Proc_IM_D_S
      };
      val: Value;
      PR:fifo;
      PWB:fifo;
      channel: channelType;
      which_fifo: which_fifo_type;
    End;

----------------------------------------------------------------------
-- Variables
----------------------------------------------------------------------
var
  HomeNode:  HomeState;
  Procs: array [Proc] of ProcState;
  Net:   array [Node] of multiset [NetMax] of Message;  -- One multiset for each destination - messages are arbitrarily reordered by the multiset
  InBox: array [Node] of array [VCType] of Message;-- If a message is not processed, it is placed in InBox, blocking that virtual channel
  msg_processed: boolean;
  ReqBuffer: array [Node] of scalarset [Proc] of Message;
  WBBuffer : array [Node] of scalarset [Proc] of Message;
  PRLUT : array [Node] of scalarset [Proc] of Message;
  ResBuffer: array [Node] of scalarset [Proc] of Message;
  LastWrite: Value; -- Used to confirm that writes are not lost; this variable would not exist in real hardware

  current_channel: channelType;
  temp_msg: Message

----------------------------------------------------------------------
-- Procedures
----------------------------------------------------------------------
Procedure Enqueue(f:fifo; msg: Message);
Begin
  assert (f.head != (f.tail + 1) % BufferSize) "a fifo overflowed!"; -- check if the queue is full
  f.buf[f.tail] := msg;
  f.tail := (f.tail + 1) % BufferSize;
End;

Function Dequeue(f:fifo): Message;
Begin
  --assert f.head != f.tail; -- check if the queue is not empty
  if (f.head = f.tail) then
    return UNDEFINED;
  endif;
  var msg := f.buf[f.head];
  f.head := (f.head + 1) % BufferSize;
  return msg;
End;

Function Peek(f:fifo): Message;
Begin
  --assert f.head != f.tail; -- check if the queue is not empty
  if (f.head = f.tail) then
    return UNDEFINED;
  endif;
  var msg := f.buf[f.head];
  return msg;
End;

Procedure ToBuffer(
            f:fifo;
            mtype:MessageType;
            dest: Node;
            src:Node;
            val:Value;
          );
var msg:Message; 
Begin
  -- data msg counts as WB, everything else counts as pending request
  --Assert (MultiSetCount(i:Net[dst], true) < NetMax) "Too many messages";
  msg.mtype := mtype;
  msg.dest := dest;
  msg.src   := src;
  msg.val   := val;

  Enqueue(f, msg);
End;

Procedure ErrorUnhandledMsg(msg:Message; n:Node);
Begin
  error "Unhandled message type!";
End;

Procedure ErrorUnhandledState();
Begin
  error "Unhandled state!";
End;


-- These aren't needed for Valid/Invalid protocol, but this is a good way of writing these functions
Procedure AddToSharersList(n:Node);
Begin
  if MultiSetCount(i:HomeNode.sharers, HomeNode.sharers[i] = n) = 0
  then
    MultiSetAdd(n, HomeNode.sharers);
  endif;
End;

Function IsSharer(n:Node) : Boolean;
Begin
  return MultiSetCount(i:HomeNode.sharers, HomeNode.sharers[i] = n) > 0
End;

Procedure RemoveFromSharersList(n:Node);
Begin
  MultiSetRemovePred(i:HomeNode.sharers, HomeNode.sharers[i] = n);
End;

-- Sends a message to all sharers except rqst
Procedure SendInvReqToSharers(rqst:Node);
Begin
  for n:Node do
    if (IsMember(n, Proc) &
        MultiSetCount(i:HomeNode.sharers, HomeNode.sharers[i] = n) != 0)
    then
      if n != rqst
      then 
         Send(Inv,n,HomeType,VC2,UNDEFINED, 0,rqst); 
      endif;
    endif;
  endfor;
End;



Procedure HomeReceive(msg:Message);
var cnt:0..ProcCount;  -- for counting sharers
Begin
-- Debug output may be helpful:
--  put "Receiving "; put msg.mtype; put " on VC"; put msg.vc; 
--  put " at home -- "; put HomeNode.state;

  -- The line below is not needed in Valid/Invalid protocol.  However, the 
  -- compiler barfs if we put this inside a switch, so it is useful to
  -- pre-calculate the sharer count here
  cnt := MultiSetCount(i:HomeNode.sharers, true);


  -- default to 'processing' message.  set to false otherwise
  msg_processed := true;

  switch HomeNode.state
  case H_Invalid:
    switch msg.mtype

    case GetS:
      HomeNode.state := H_Shared;
      AddToSharersList(msg.src);
      Send(data, msg.src, HomeType, VC1, HomeNode.val,0,UNDEFINED);
    case GetM:
      HomeNode.state := H_Modified;
      HomeNode.owner := msg.src;
      Send(data, msg.src, HomeType, VC1, HomeNode.val,cnt,UNDEFINED);
    case PutS:
      Send(PutAck, msg.src, HomeType, VC1, HomeNode.val,0,UNDEFINED);
    case PutM:
      Send(PutAck, msg.src, HomeType, VC1, HomeNode.val,0,UNDEFINED);
    
    -- case GetAck:
    else
      ErrorUnhandledMsg(msg, HomeType);

    endswitch;

  case H_Shared: 
    switch msg.mtype
    case GetS:
      AddToSharersList(msg.src);     
      Send(data, msg.src, HomeType, VC1, HomeNode.val,0,UNDEFINED);
                 
    case GetM:
      HomeNode.owner := msg.src;
      if IsSharer(msg.src) then
         if cnt = 1 then
           HomeNode.state := H_Modified;   
           undefine HomeNode.sharers;        
         else
          HomeNode.state := HT_SM;
          HomeNode.ackcnt := cnt -1;
          SendInvReqToSharers(msg.src);
          undefine HomeNode.sharers;
         endif;

         Send(data, msg.src, HomeType, VC1, HomeNode.val,cnt-1,UNDEFINED);
      else 
         HomeNode.state := HT_SM;
         HomeNode.ackcnt := cnt;
         SendInvReqToSharers(msg.src);
         undefine HomeNode.sharers;
         Send(data, msg.src, HomeType, VC1, HomeNode.val,cnt,UNDEFINED);
      endif;
      

      case PutS:
      if IsSharer(msg.src) then
         if cnt = 1 then
          HomeNode.state := H_Invalid;
         endif;
         endif;
          RemoveFromSharersList(msg.src);
          Send(PutAck, msg.src, HomeType, VC1, UNDEFINED,0,UNDEFINED);
      case PutM:
          if IsSharer(msg.src) then
            if cnt = 1 then
             HomeNode.state := H_Invalid;
            --  undefine HomeNode.sharers;
          endif;
          endif;
          RemoveFromSharersList(msg.src);
          Send(PutAck, msg.src, HomeType, VC1, UNDEFINED,0,UNDEFINED);
      
      -- case GetAck:
          
      -- case data :
      --     HomeNode.val := msg.val;
    else
      ErrorUnhandledMsg(msg, HomeType);

    endswitch;

  case H_Modified:
    switch msg.mtype
   
    case GetS:
      HomeNode.state := HT_MS;
      AddToSharersList(msg.src);
      AddToSharersList(HomeNode.owner);
      Send(FwdGetS, HomeNode.owner, HomeType, VC2, UNDEFINED,0,msg.src);
      undefine HomeNode.owner;

    case GetM:
    	HomeNode.state := HT_MM;
      Send(FwdGetM, HomeNode.owner, HomeType, VC2, UNDEFINED,0,msg.src);
      HomeNode.owner :=msg.src;
    
    case PutS:
      
      Send(PutAck, msg.src, HomeType, VC1, UNDEFINED,0,UNDEFINED);
    
    case PutM:
      if HomeNode.owner =msg.src then
         HomeNode.state := H_Invalid;
         HomeNode.val := msg.val;
        --  LastWrite:= msg.val;
         
         undefine HomeNode.owner;
         Send(PutAck, msg.src, HomeType, VC1, UNDEFINED,0,UNDEFINED);
      else 
         Send(PutAck, msg.src, HomeType, VC1, UNDEFINED,0,UNDEFINED);
      endif;
    -- case GetAck:
     
    
    else
      ErrorUnhandledMsg(msg, HomeType);

    endswitch;
    
  case HT_SM:
    switch msg.mtype

    case GetS:
      msg_processed := false;

    case GetM:
      msg_processed := false;

    case PutS:
      msg_processed := false;  

    case PutM:
      msg_processed := false;

    -- case data:
    --   msg_processed := false;
    
    case InvAck:
      HomeNode.ackcnt := HomeNode.ackcnt-1;
       if HomeNode.ackcnt =0 then
          HomeNode.state := H_Modified;
        endif;
    -- case Fwdack:
    else
      ErrorUnhandledMsg(msg, HomeType);

    endswitch;
    
  case HT_MS:
    switch msg.mtype

    case GetS:
      msg_processed := false;

    case GetM:
      msg_processed := false;

    case PutS:
      msg_processed := false;  

    case PutM:
      msg_processed := false;

    -- case data:
    --  if cnt =0 then 
    --  HomeNode.state := H_Invalid;
   
     
    --  else
    --  HomeNode.state := H_Shared;
    --  endif;
    -- HomeNode.state := H_Shared;
    -- HomeNode.val := msg.val;
    case Fwdack:
     if cnt >0 then 
     HomeNode.state := H_Shared;    
     else
     HomeNode.state := H_Invalid;
     endif;
      HomeNode.val := msg.val;
      --  LastWrite:= msg.val;
    else
      ErrorUnhandledMsg(msg, HomeType);

    endswitch;

  case HT_MM:
    switch msg.mtype

    case GetS:
      msg_processed := false;

    case GetM:
      msg_processed := false;

    case PutS:
      msg_processed := false;  

    case PutM:
      msg_processed := false;

    -- case data:
    --   msg_processed := false;
    
    case Fwdack:
      HomeNode.state := H_Modified;
    
    else
      ErrorUnhandledMsg(msg, HomeType);

    endswitch;
  endswitch;
End;


Procedure ProcReceive(msg:Message; p:Proc);
Begin
--  put "Receiving "; put msg.mtype; put " on VC"; put msg.vc; 
--  put " at proc "; put p; put "\n";

  -- default to 'processing' message.  set to false otherwise
  msg_processed := true;

  alias ps:Procs[p].state do
  alias pv:Procs[p].val do
  alias pack:Procs[p].ackcnt do
  

  switch ps
    case Proc_I:
        ErrorUnhandledMsg(msg, p);

    case Proc_S:     
      if (msg.src = p | msg.dest = p) then --own
        switch msg.mtype
          case Upg:
            ErrorUnhandledMsg(msg, p);
          case PutM:
            ErrorUnhandledMsg(msg, p);
          case Data:
            ErrorUnhandledMsg(msg, p);
          endswitch;
      else --other
        switch msg.mtype
          case GetM:
            ps := Proc_I;
          case Upg:
            ps := Proc_I;
        endswitch;
      endif;

    case Proc_M:     
      if (msg.src = p | msg.dest = p) then --own
        switch msg.mtype
          case Data:
            ErrorUnhandledMsg(msg, p);
          case Upg:
            ErrorUnhandledMsg(msg, p);
          case PutM:
            ErrorUnhandledMsg(msg, p);
      else --other
        switch msg.mtype
          case GetS:
            ps := Proc_MS_WB;
            ToBuffer(p.PR, PutM, HomeType, p, pv);
          case GetM:
            ps := Proc_MI_WB;
            ToBuffer(p.PR, PutM, HomeType, p, pv);
          case Upg:
            ErrorUnhandledMsg(msg, p);
          case PutM:
            ErrorUnhandledMsg(msg, p);
      endif;

    case Proc_IS_D:
      if (msg.src = p | msg.dest = p) then --own
        switch msg.mtype
          case Data:
            ps := Proc_S;
            pv := msg.val;
          case Upg:
            ErrorUnhandledMsg(msg, p);
          case PutM:
            ErrorUnhandledMsg(msg, p);
      else --other
        switch msg.mtype
          case GetS:
            
          case GetM:
            ps := Proc_IS_D_I;
          case Upg:
            ps := Proc_IS_D_I;
          case PutM:
            
      endif;

    case Proc_IM_D:
      if (msg.src = p | msg.dest = p) then --own
        switch msg.mtype
          case Data:
            ps := Proc_M;
            LastWrite := msg.val; --write
          case Upg:
            ErrorUnhandledMsg(msg, p);
          case PutM:
            ErrorUnhandledMsg(msg, p);
      else --other
        switch msg.mtype
          case GetS:
            ErrorUnhandledMsg(msg, p);
          case GetM:
            ErrorUnhandledMsg(msg, p);
          case Upg:
            ErrorUnhandledMsg(msg, p);
          case PutM:
            ErrorUnhandledMsg(msg, p);
      endif;

    case Proc_SM_W:     
      if (msg.src = p | msg.dest = p) then --own
        switch msg.mtype
          case Data:
            ErrorUnhandledMsg(msg, p);
          case Upg:
            ps := Proc_M;
            pv := msg.val;
            LastWrite := msg.val; --write
          case PutM:
            ErrorUnhandledMsg(msg, p);
      else --other
        switch msg.mtype
          case GetS:
            
          case GetM:
            ps := Proc_I;
            --reissue: not last write
          case Upg:
            ps := Proc_I;
            --reissue: not last write
          case PutM:
            ErrorUnhandledMsg(msg, p);
      endif;

    case Proc_MI_WB:     
      if (msg.src = p | msg.dest = p) then --own
        switch msg.mtype
          case Data:
            ErrorUnhandledMsg(msg, p);
          case Upg:
            ErrorUnhandledMsg(msg, p);
          case PutM:
            ps := I;
            ToBuffer(p.WB, Data, HomeType, p, pv);
      else --other
        switch msg.mtype
          case GetS:
            
          case GetM:
            
          case Upg:
            ErrorUnhandledMsg(msg, p);
          case PutM:
            ErrorUnhandledMsg(msg, p);
      endif;

      case Proc_MS_WB:
      if (msg.src = p | msg.dest = p) then --own
        switch msg.mtype
          case Data:
            ErrorUnhandledMsg(msg, p);
          case Upg:
            ErrorUnhandledMsg(msg, p);
          case PutM:
            ps := S;
            ToBuffer(p.WB, Data, HomeType, p, pv);
      else --other
        switch msg.mtype
          case GetS:
            
          case GetM:
            ps := Proc_MI_WB;
          case Upg:
            ErrorUnhandledMsg(msg, p);
          case PutM:
            ErrorUnhandledMsg(msg, p);
      endif;

    case Proc_IM_D_I:
      if (msg.src = p | msg.dest = p) then --own
        switch msg.mtype
          case Data:
            ps := Proc_MI_WB;
            LastWrite := msg.val; --write
          case Upg:
            ErrorUnhandledMsg(msg, p);
          case PutM:
            ErrorUnhandledMsg(msg, p);
      else --other
        switch msg.mtype
          case GetS:
            
          case GetM:
            
          case Upg:
            ErrorUnhandledMsg(msg, p);
          case PutM:
            
      endif;

    case Proc_IS_D_I:
      if (msg.src = p | msg.dest = p) then --own
        switch msg.mtype
          case Data:
            ps := I;
            LastWrite := msg.val; --write
          case Upg:
            ErrorUnhandledMsg(msg, p);
          case PutM:
            ErrorUnhandledMsg(msg, p);
      else --other
        switch msg.mtype
          case GetS:
            
          case GetM:
            
          case Upg:
            
          case PutM:
            
      endif;

    case Proc_IM_D_S:
      if (msg.src = p | msg.dest = p) then --own
        switch msg.mtype
          case Data:
            ps := Proc_MS_WB;
            ToBuffer(p.PR, PutM, HomeType, p, UNDEFINED);
          case Upg:
            ErrorUnhandledMsg(msg, p);
          case PutM:
            ErrorUnhandledMsg(msg, p);
      else --other
        switch msg.mtype
          case GetS:
            
          case GetM:
            ps := Proc_IM_D_I;
          case Upg:
            ErrorUnhandledMsg(msg, p);
          case PutM:
            
      endif;

  ----------------------------
  -- Error catch
  ----------------------------
  else
    ErrorUnhandledState();

  endswitch;
  
  endalias;
  endalias;
  endalias;
End;

----------------------------------------------------------------------
-- Rules
----------------------------------------------------------------------

-- core events

ruleset n:Proc Do
  alias p:Procs[n] Do

	ruleset v:Value Do
  	rule "@ P store"
   	 (p.state = Proc_I | p.state = Proc_S | p.state = Proc_M | p.state = Proc_MI_WB | p.state = Proc_MS_WB)
    	==>
      switch p.state
        case Proc_I:
          ToBuffer(p.PR, GetM, HomeType, p, UNDEFINED);
          p.state := Proc_IM_D;
          
        case Proc_S:
          ToBuffer(p.PR, Upg, HomeType, p, v); --forward value to itself
          p.state := Proc_SM_W;

        case Proc_M:
          pv := v;
          LastWrite := v;

        case Proc_MI_WB:
          pv := v;
          LastWrite := v;

        case Proc_MS_WB:
          pv := v;
          LastWrite := v;

        else
      
  	endrule;
	endruleset;
  
  rule "@ P load"
    (p.state = Proc_I | p.state = Proc_S | p.state = Proc_MI_WB | p.state = Proc_MS_WB | p.state = Proc_M )
  ==>
    switch p.state
      case Proc_I:
        ToBuffer(p.PR, GetS, HomeType, p, UNDEFINED);
        p.state := Proc_IS_D;

        case Proc_S:

        case Proc_MI_WB:

        case Proc_MS_WB:   

        case Proc_M:     
      else

    endswitch;
  endrule;

  rule "@ P evict"
    ( p.state = Proc_S | p.state = Proc_M | p.state = Proc_MS_WB )
  ==>
    switch p.state
      case Proc_S:
        p.state := Proc_I;

      case Proc_M:
        ToBuffer(p.PR, PutM, HomeType, p, p.val);      
        p.state := Proc_MI_WB;

      case Proc_MS_WB:
        p.state := Proc_MI_WB;
      
      else

    endswitch;
  endrule;

----------- new bus msg passing rules ----------------------
-- procs can only send one message per window

ruleset n:Proc Do
  alias p:Procs[n] Do
    rule "proc send to bus"
      (current_channel = p.channel)
    ==>
      if (p.which_fifo) then
        --PR dequeue
        temp_msg := Dequeue(p.PR);
        if(!isundefined(temp_msg)) then
          for i:Proc do --all proc receive message
            ProcReceive(temp_msg, i);
          endfor;
          Enqueue(HomeNode.PRLUT, temp_msg);
        endif;
      else 
        --PWB dequeue (WB are data message)
        temp_msg := Dequeue(p.PWB);
        if(!isundefined(temp_msg)) then
          HomeReceive(temp_msg); 
        endif;
      endif;

      p.which_fifo := !p.which_fifo; --proc fifo arbitor
      current_channel := (current_channel+1) % (ProcCount+1); -- all nodes arbitor (proc and home rotate)
  endalias;
endruleset;

--mem consume LUT (can it consume multiple?)
rule "mem consume LUT"
    (current_channel = 0)
  ==>
    temp_msg := Peek(HomeNode.PRLUT);
    if(!isundefined(temp_msg)) then
      HomeReceive(temp_msg);
      if (msg_processed) then
        Dequeue(HomeNode.PRLUT);
      endif;
    endif;
    current_channel := (current_channel+1) % (ProcCount+1);
endrule

----------------------------------------------------------------------
-- Startstate
----------------------------------------------------------------------
startstate

	For v:Value do
  -- home node initialization
  HomeNode.state := H_Invalid;
  undefine HomeNode.owner;
  undefine HomeNode.sharers;
  HomeNode.ackcnt :=0;
  HomeNode.val := v;
	endfor;
	LastWrite := HomeNode.val;
  
  -- processor initialization
  for i:Proc do
    Procs[i].state := P_Invalid;
    Procs[i].ackcnt := 0;
    undefine Procs[i].val;
    Procs[i].channel := i+1;
    which_fifo := true; --start with PR
  endfor;

  HomeNode.channel := 0;

  -- network initialization
  undefine Net;
endstartstate;

----------------------------------------------------------------------
-- Invariants
----------------------------------------------------------------------

invariant "Invalid implies empty owner"
  HomeNode.state = H_Invalid | HomeNode.state = H_Shared
    ->
      IsUndefined(HomeNode.owner);

-- invariant "value in memory matches value of last write, when invalid"
--      HomeNode.state = H_Invalid 
--     ->
-- 			HomeNode.val = LastWrite;

invariant "values in valid state match last write"
  Forall n : Proc Do	
     Procs[n].state = P_Modified
    ->
			Procs[n].val = LastWrite --LastWrite is updated whenever a new value is created 
	end;
	
invariant "value is undefined while invalid"
  Forall n : Proc Do	
     Procs[n].state = P_Invalid
    ->
			IsUndefined(Procs[n].val)
	end;
	

-- Here are some invariants that are helpful for validating shared state.

invariant "modified implies empty sharers list"
  HomeNode.state = H_Modified
    ->
      MultiSetCount(i:HomeNode.sharers, true) = 0;

invariant "Invalid implies empty sharer list"
  HomeNode.state = H_Invalid
    ->
      MultiSetCount(i:HomeNode.sharers, true) = 0;

invariant "values in memory matches value of last write, when shared or invalid"
  Forall n : Proc Do	
     HomeNode.state = H_Shared | HomeNode.state = H_Invalid
    ->
			HomeNode.val = LastWrite
	end;

invariant "values in shared state match memory"
  Forall n : Proc Do	
     HomeNode.state = H_Shared & Procs[n].state = P_Shared
    ->
			HomeNode.val = Procs[n].val
	end;

invariant "home in M state implies owner exists"
  HomeNode.state = H_Modified
    ->
      HomeNode.owner != HomeType;

invariant "home in S state implies non-empty sharer list"
  HomeNode.state = H_Shared
    ->
      MultiSetCount(i: HomeNode.sharers, true) != 0;

  invariant "processor in Modified state,  no Sharers"
  Forall n : Proc Do
    Forall m : Proc Do
      ((Procs[n].state = P_Modified) & (n != m)) 
        -> 
          (Procs[m].state != P_Shared & Procs[m].state != P_Modified)
    end
  end;

